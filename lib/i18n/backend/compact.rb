# frozen_string_literal: true

# The Compact module optimizes the memory footprint of the translations store
# by replacing the deeply nested Hash tree with a compact columnar representation
# after all translations have been loaded.
#
# It achieves memory savings through several techniques:
#
# 1. **Shared key schema**: All locales share a single flat Hash mapping
#    dot-separated Symbol keys to integer indices. This eliminates per-locale
#    key storage overhead — the single schema Hash is amortized across all locales.
#
# 2. **Columnar value storage**: Each locale's values are stored in a flat Array
#    indexed by the schema positions. Arrays have ~3x less overhead than Hashes
#    with the same number of entries.
#
# 3. **String deduplication**: All string leaf values are deduplicated using
#    Ruby's String#-@ (frozen string dedup), so identical translations across
#    locales share a single String object in memory.
#
# 4. **Reduced object count**: The deeply nested Hash tree (thousands of
#    intermediate Hash objects) is replaced with a single schema Hash + one
#    Array per locale.
#
# To enable it, include the Compact module in your backend:
#
#   I18n::Backend::Simple.include(I18n::Backend::Compact)
#
# Or create a custom backend class:
#
#   class CompactBackend < I18n::Backend::Simple
#     include I18n::Backend::Compact
#   end
#
# The compaction happens automatically after `eager_load!` is called, or can
# be triggered manually by calling `compact!` on the backend.
#
# After compaction, calling `store_translations` will decompact the
# affected locale (reverting it to nested Hash mode) until `compact!` is
# called again.
#
# == Trade-offs
#
# * Leaf lookups (the common case) are O(1) — schema hash lookup + array index.
# * Subtree lookups (e.g., I18n.t(:errors) returning a whole Hash) require
#   reconstructing the nested structure on demand. This is slower than the
#   Simple backend but is an uncommon operation in production.
# * After compaction, the backend is effectively read-only for best
#   performance. Calling store_translations will decompact the locale.
#
module I18n
  module Backend
    module Compact
      # Trigger compaction after eager loading.
      def eager_load!
        super
        compact!
      end

      # Compact all loaded translations into an optimized columnar structure.
      #
      # This should be called after all translations have been loaded (e.g.,
      # after `eager_load!` in production).
      def compact!
        init_translations unless initialized?

        @compacted_locales ||= {}
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}
        @subtree_keys ||= nil

        translations.each do |locale, tree|
          next if @compacted_locales[locale]
          compact_locale!(locale, tree)
        end

        # Build the subtree key sets for efficient subtree reconstruction.
        build_subtree_index!
      end

      def store_translations(locale, data, options = EMPTY_HASH)
        locale = locale.to_sym

        # If this locale was compacted, we need to rebuild the nested tree
        # from the flat index so that the new data can be deep-merged in.
        if @compacted_locales&.dig(locale)
          rebuild_nested_tree!(locale)
        end

        super
      end

      def reload!
        @schema = nil
        @schema_index = nil
        @value_arrays = nil
        @compacted_locales = nil
        @subtree_keys = nil
        super
      end

      protected

      def lookup(locale, key, scope = [], options = EMPTY_HASH)
        init_translations unless initialized?

        # If this locale has been compacted, use the fast columnar lookup.
        if @compacted_locales&.dig(locale)
          return compact_lookup(locale, key, scope, options)
        end

        # Not compacted yet — use the original Simple lookup.
        super
      end

      private

      # Sentinel object to mark keys that are subtree roots (not leaves).
      SUBTREE_MARKER = Object.new.freeze

      # Compact a single locale's translation tree into the columnar structure.
      def compact_locale!(locale, tree)
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}
        @compacted_locales ||= {}

        values = []
        flatten_and_dedup(nil, tree, values)

        @value_arrays[locale] = values.freeze
        @compacted_locales[locale] = true

        # Clear the nested tree for this locale to free memory.
        translations[locale] = build_locale_marker
      end

      # Build a minimal marker hash that keeps available_locales working.
      def build_locale_marker
        marker = Concurrent::Hash.new
        marker[:_compacted] = true
        marker
      end

      # Recursively flatten a nested hash, assigning schema indices and
      # storing values in the values array.
      def flatten_and_dedup(prefix, hash, values)
        hash.each do |key, value|
          flat_key = prefix ? :"#{prefix}.#{key}" : key.to_s.to_sym

          # Get or create the schema index for this key.
          idx = @schema[flat_key]
          unless idx
            idx = @schema_index
            @schema[flat_key] = idx
            @schema_index += 1
          end

          # Ensure the values array is large enough.
          values[idx] = case value
          when Hash
            SUBTREE_MARKER
          when String
            -value
          when Array
            dedup_array(value)
          else
            value
          end

          # Recurse into nested hashes.
          flatten_and_dedup(flat_key, value, values) if value.is_a?(Hash)
        end
      end

      # Build an index of which schema keys are subtree roots and what their
      # direct children are. This is built once after all locales are compacted
      # and shared across locales.
      def build_subtree_index!
        @subtree_keys = {}

        @schema.each_key do |sym_key|
          str_key = sym_key.to_s
          last_dot = str_key.rindex(".")
          next unless last_dot

          parent = str_key[0, last_dot].to_sym
          (@subtree_keys[parent] ||= []) << sym_key
        end

        # Freeze the children arrays.
        @subtree_keys.each_value(&:freeze)
        @subtree_keys.freeze
      end

      # Perform a lookup from the compacted columnar structure.
      def compact_lookup(locale, key, scope, options)
        flat_key = I18n::Backend::Flatten.normalize_flat_keys(
          locale, key, scope, options[:separator]
        )

        # Strip the locale prefix from the flat key.
        locale_prefix = "#{locale}."
        if flat_key.start_with?(locale_prefix)
          flat_key = flat_key[locale_prefix.length..]
        end

        sym_key = flat_key.to_sym
        idx = @schema[sym_key]
        return nil unless idx

        values = @value_arrays[locale]
        return nil unless values

        result = values[idx]
        return nil if result.nil?

        # If the result is the subtree marker, reconstruct the subtree on demand.
        if result.equal?(SUBTREE_MARKER)
          result = reconstruct_subtree(locale, sym_key)
        end

        result = resolve_entry(locale, key, result, Utils.except(options.merge(:scope => nil), :count)) if result.is_a?(Symbol)
        result
      end

      # Reconstruct a nested Hash subtree using the subtree index.
      def reconstruct_subtree(locale, parent_key)
        children = @subtree_keys[parent_key]
        return {} unless children

        values = @value_arrays[locale]
        result = {}

        children.each do |child_sym|
          child_str = child_sym.to_s
          parent_str = parent_key.to_s
          local_part = child_str[(parent_str.length + 1)..]
          local_key = local_part.to_sym

          idx = @schema[child_sym]
          value = values[idx]
          next if value.nil?

          if value.equal?(SUBTREE_MARKER)
            result[local_key] = reconstruct_subtree(locale, child_sym)
          else
            result[local_key] = value
          end
        end

        result
      end

      # Rebuild the nested tree for a locale from the compacted data.
      def rebuild_nested_tree!(locale)
        values = @value_arrays.delete(locale)
        @compacted_locales.delete(locale)

        return unless values

        nested = Concurrent::Hash.new
        @schema.each do |sym_key, idx|
          value = values[idx]
          next if value.nil? || value.equal?(SUBTREE_MARKER)

          keys = sym_key.to_s.split(".")
          target = nested
          keys[0..-2].each do |k|
            target[k.to_sym] ||= {}
            target = target[k.to_sym]
          end
          target[keys.last.to_sym] = value
        end

        translations[locale] = nested
      end

      # Deduplicate strings within an array, recursively handling nested structures.
      def dedup_array(array)
        array.map do |element|
          case element
          when String then -element
          when Array then dedup_array(element)
          when Hash then dedup_hash_values(element)
          else element
          end
        end.freeze
      end

      # Deduplicate string values within a hash (used for hashes inside arrays).
      def dedup_hash_values(hash)
        result = {}
        hash.each do |k, v|
          result[k] = case v
          when String then -v
          when Array then dedup_array(v)
          when Hash then dedup_hash_values(v)
          else v
          end
        end
        result
      end
    end
  end
end
