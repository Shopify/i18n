# frozen_string_literal: true

# The Compact module optimizes the memory footprint of the translations store
# by replacing the deeply nested Hash tree with a compact columnar representation
# backed by a binary string table after all translations have been loaded.
#
# It achieves memory savings through several techniques:
#
# 1. **Shared key schema**: All locales share a single flat Hash mapping
#    dot-separated Symbol keys to integer indices. This eliminates per-locale
#    key storage overhead — the single schema Hash is amortized across all locales.
#
# 2. **Binary string table**: All unique translation strings across all locales
#    are packed into a single binary String buffer. Individual translations are
#    retrieved by slicing the buffer at stored offset+length positions. This
#    eliminates tens of thousands of individual String objects (each with ~40-46
#    bytes of per-object overhead in Ruby), replacing them with one large
#    contiguous allocation.
#
# 3. **Integer-packed value arrays**: Each locale's values are stored in a flat
#    Array containing only immediate-value Integers (zero heap overhead), nil,
#    or a sentinel marker. String translations are encoded as packed integers:
#    `(offset << 16) | length`, where offset and length index into the binary
#    string table. Non-string values (Arrays, Symbols, Procs, etc.) are stored
#    in a shared side table and referenced by negative integers.
#
# 4. **Reduced object count**: The deeply nested Hash tree (thousands of
#    intermediate Hash objects and String objects) is replaced with a single
#    schema Hash + one Array per locale + one binary buffer + one side table.
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
# == Caching
#
# The compacted representation can be serialized to a cache file so that
# subsequent boots skip YAML parsing and compaction entirely:
#
#   I18n.backend.eager_load!(cache_path: "/tmp/i18n_compact.cache")
#
# Or with content-based cache invalidation (slower to compute but survives
# mtime resets during deploys):
#
#   I18n.backend.eager_load!(cache_path: "/tmp/i18n_compact.cache", cache_digest: true)
#
# The cache is invalidated automatically when the set of load_path files or
# their contents/mtimes change.
#
# Proc values (e.g., pluralization rules from .rb locale files) cannot be
# serialized. When loading from cache, .rb locale files are re-evaluated to
# reconstruct any Proc values.
#
# == Trade-offs
#
# * Leaf lookups (the common case) are O(1) — schema hash lookup + array
#   index + buffer slice. The buffer slice allocates a new String per lookup,
#   similar to the existing `entry.dup` behavior in Backend::Base#translate.
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
      #
      # Options:
      #   cache_path:   Path to a cache file. If present and valid, the
      #                 compacted index is loaded from it instead of rebuilding.
      #                 If absent or stale, the index is rebuilt and written.
      #   cache_digest: When true, use SHA256 content digests for cache
      #                 invalidation instead of file mtimes. Slower to compute
      #                 but survives mtime resets (e.g., during deploys).
      def eager_load!(cache_path: nil, cache_digest: false)
        # When a cache path is provided, try to load directly from cache
        # BEFORE parsing any YAML files. This skips the expensive
        # load_translations step entirely on cache hit.
        if cache_path
          fingerprint = compute_fingerprint(digest: cache_digest)
          if load_cache(cache_path, fingerprint)
            @initialized = true
            return
          end
        end

        super()
        compact!(cache_path: cache_path, cache_digest: cache_digest,
                 _fingerprint: fingerprint)
      end

      # Compact all loaded translations into an optimized columnar structure
      # backed by a binary string table.
      #
      # This should be called after all translations have been loaded (e.g.,
      # after `eager_load!` in production).
      #
      # Options:
      #   cache_path:   Path to a cache file (see eager_load!).
      #   cache_digest: Use content digests for invalidation (see eager_load!).
      def compact!(cache_path: nil, cache_digest: false, _fingerprint: nil)
        init_translations unless initialized?

        @compacted_locales ||= {}
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}

        # Check if any locales need compaction.
        has_pending = translations.any? { |locale, _| !@compacted_locales[locale] }

        # Nothing to do if all locales are already compacted.
        return if !has_pending

        # Try loading from cache if a path was provided.
        if cache_path
          fingerprint = _fingerprint || compute_fingerprint(digest: cache_digest)
          if load_cache(cache_path, fingerprint)
            return
          end
        end

        # If some locales are already compacted and we have new locales to add,
        # rebuild everything from scratch. This is simpler than remapping
        # packed integer references, and compact! is called rarely (once at boot).
        if @compacted_locales.any?
          @compacted_locales.each_key do |locale|
            rebuild_nested_tree!(locale)
          end
        end

        # Reset the compacted state — we'll rebuild all locales.
        @schema.clear
        @schema_index = 0
        @value_arrays.clear
        @compacted_locales.clear

        # Build fresh string and object tables.
        @_string_builder = StringTableBuilder.new
        @_objects_builder = []

        translations.each do |locale, tree|
          compact_locale!(locale, tree)
        end

        # Finalize the string table into a single frozen binary buffer.
        @string_table = @_string_builder.to_buffer
        @string_table_encodings = @_string_builder.encodings
        @objects_table = @_objects_builder.freeze

        # Clean up builders — they're no longer needed.
        @_string_builder = nil
        @_objects_builder = nil

        # Build the subtree key sets for efficient subtree reconstruction.
        build_subtree_index!

        # Write cache for next boot.
        if cache_path
          fingerprint ||= compute_fingerprint(digest: cache_digest)
          dump_cache(cache_path, fingerprint)
        end
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
        @string_table = nil
        @string_table_encodings = nil
        @objects_table = nil
        @_string_builder = nil
        @_objects_builder = nil
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

      # Sentinel integer value to mark keys that are subtree roots.
      # We use a specific large negative number that won't collide with
      # object table references (which are -(index+1), starting at -1).
      SUBTREE_SENTINEL = -(1 << 62)

      # Encoding IDs for the string table. We store encoding as a small
      # integer to avoid per-string Encoding object references.
      ENCODING_UTF8    = 0
      ENCODING_ASCII   = 1
      ENCODING_BINARY  = 2
      ENCODING_OTHER   = 3  # fallback: store Encoding index

      ENCODING_TABLE = {
        ENCODING_UTF8   => Encoding::UTF_8,
        ENCODING_ASCII  => Encoding::US_ASCII,
        ENCODING_BINARY => Encoding::BINARY,
      }.freeze

      # Helper class to build the binary string table during compaction.
      # Deduplicates identical strings so each unique string is stored once.
      class StringTableBuilder
        def initialize
          @buffer = String.new(encoding: Encoding::BINARY, capacity: 4096)
          @index = {}  # content_hash => [offset, length, encoding_id]
          @encodings = []  # parallel to @buffer positions: maps offset => encoding_id
          @encoding_map = {}  # offset => encoding_id
        end

        # Add a string to the table, returning [offset, length, encoding_id].
        # Deduplicates by content + encoding.
        def add(str)
          enc_id = encoding_id(str.encoding)
          key = [str, enc_id]
          existing = @index[key]
          return existing if existing

          offset = @buffer.bytesize
          length = str.bytesize
          @buffer << str.b  # append as binary
          @encoding_map[offset] = enc_id

          entry = [offset, length, enc_id].freeze
          @index[key] = entry
          entry
        end

        # Finalize the buffer into a frozen binary string.
        def to_buffer
          @buffer.freeze
        end

        # Return the encoding map (offset => encoding_id).
        def encodings
          @encoding_map.freeze
        end

        private

        def encoding_id(encoding)
          case encoding
          when Encoding::UTF_8    then ENCODING_UTF8
          when Encoding::US_ASCII then ENCODING_ASCII
          when Encoding::BINARY   then ENCODING_BINARY
          else ENCODING_OTHER
          end
        end
      end

      # Maximum string byte length that can be packed into a single integer.
      # Strings longer than this are stored in the objects table instead.
      MAX_PACKED_STRING_LENGTH = 0xFFFF  # 65,535 bytes

      # Pack a string table reference into a single Integer.
      # Format: (encoding_id << 52) | (offset << 16) | length
      #
      # This allows:
      # - offset up to 2^36 = 64 GB (way more than any translation set)
      # - length up to 2^16 = 64 KB per string (sufficient for translations)
      # - encoding_id up to 2^4 = 16 encodings
      # - Total fits in a 56-bit positive integer (Ruby Fixnum, zero allocation)
      def pack_string_ref(offset, length, encoding_id)
        (encoding_id << 52) | (offset << 16) | length
      end

      # Unpack a string reference back into [offset, length, encoding_id].
      def unpack_string_ref(packed)
        encoding_id = (packed >> 52) & 0xF
        offset = (packed >> 16) & 0xFFFFFFFFFFF  # 36 bits
        length = packed & 0xFFFF                   # 16 bits
        [offset, length, encoding_id]
      end

      # Resolve a packed integer back to a String from the binary buffer.
      def resolve_string(packed)
        offset, length, encoding_id = unpack_string_ref(packed)
        str = @string_table.byteslice(offset, length)
        encoding = ENCODING_TABLE[encoding_id] || Encoding::UTF_8
        str.force_encoding(encoding)
        str
      end

      # Check if a value array entry is a string reference (positive Integer).
      def string_ref?(value)
        value.is_a?(Integer) && value >= 0
      end

      # Check if a value array entry is an object table reference (negative Integer, not SUBTREE_SENTINEL).
      def object_ref?(value)
        value.is_a?(Integer) && value < 0 && value != SUBTREE_SENTINEL
      end

      # Check if a value array entry is the subtree marker.
      def subtree_marker?(value)
        value.equal?(SUBTREE_SENTINEL)
      end

      # Compact a single locale's translation tree into the columnar structure.
      def compact_locale!(locale, tree)
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}
        @compacted_locales ||= {}

        values = []
        flatten_into_columns(nil, tree, values)

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
      # storing values in the value array as packed integers.
      def flatten_into_columns(prefix, hash, values)
        hash.each do |key, value|
          flat_key = prefix ? :"#{prefix}.#{key}" : key.to_s.to_sym

          # Get or create the schema index for this key.
          idx = @schema[flat_key]
          unless idx
            idx = @schema_index
            @schema[flat_key] = idx
            @schema_index += 1
          end

          values[idx] = case value
          when Hash
            SUBTREE_SENTINEL
          when String
            if value.bytesize <= MAX_PACKED_STRING_LENGTH
              # Pack string into the binary table, store packed integer reference.
              entry = @_string_builder.add(value)
              pack_string_ref(entry[0], entry[1], entry[2])
            else
              # String too long for packed format — store in objects table.
              obj_idx = @_objects_builder.size
              @_objects_builder << value
              -(obj_idx + 1)
            end
          else
            # Arrays, Symbols, Procs, booleans, numbers, nil —
            # store in the objects side table, reference by negative index.
            obj_idx = @_objects_builder.size
            @_objects_builder << value
            -(obj_idx + 1)
          end

          # Recurse into nested hashes.
          flatten_into_columns(flat_key, value, values) if value.is_a?(Hash)
        end
      end

      # Build an index of which schema keys are subtree roots and what their
      # direct children are. Built once after all locales are compacted.
      def build_subtree_index!
        @subtree_keys = {}

        @schema.each_key do |sym_key|
          str_key = sym_key.to_s
          last_dot = str_key.rindex(".")
          next unless last_dot

          parent = str_key[0, last_dot].to_sym
          (@subtree_keys[parent] ||= []) << sym_key
        end

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

        packed = values[idx]
        return nil if packed.nil?

        result = decode_value(packed)

        # If the result is :_subtree, reconstruct the subtree on demand.
        if result == :_subtree
          result = reconstruct_subtree(locale, sym_key)
        end

        result = resolve_entry(locale, key, result, Utils.except(options.merge(:scope => nil), :count)) if result.is_a?(Symbol)
        result
      end

      # Decode a value from the value array.
      def decode_value(packed)
        if subtree_marker?(packed)
          :_subtree
        elsif string_ref?(packed)
          resolve_string(packed)
        elsif object_ref?(packed)
          @objects_table[-(packed + 1)]
        else
          packed  # shouldn't happen, but handle gracefully
        end
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
          packed = values[idx]
          next if packed.nil?

          if subtree_marker?(packed)
            result[local_key] = reconstruct_subtree(locale, child_sym)
          else
            result[local_key] = decode_value(packed)
          end
        end

        result
      end

      # Rebuild the nested tree for a locale from the compacted data.
      # Called when store_translations is invoked on a compacted locale.
      def rebuild_nested_tree!(locale)
        values = @value_arrays.delete(locale)
        @compacted_locales.delete(locale)

        return unless values

        nested = Concurrent::Hash.new
        @schema.each do |sym_key, idx|
          packed = values[idx]
          next if packed.nil? || subtree_marker?(packed)

          value = decode_value(packed)
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

      # ================================================================
      # Cache serialization
      # ================================================================

      # Magic bytes and version for the cache file format.
      CACHE_MAGIC   = "I18NC"
      CACHE_VERSION = 1

      # Compute a fingerprint of all load_path files for cache invalidation.
      #
      # When digest: false (default), uses file paths + mtimes. This is fast
      # but won't survive mtime resets (e.g., git checkout, rsync, deploy).
      #
      # When digest: true, uses SHA256 of file contents. Slower but robust
      # across deploys.
      def compute_fingerprint(digest: false)
        files = I18n.load_path.flatten.sort
        if digest
          require 'digest/sha2'
          d = Digest::SHA256.new
          files.each do |f|
            d.update(f)
            d.update("\0")
            d.update(File.read(f)) if File.exist?(f)
            d.update("\0")
          end
          d.hexdigest
        else
          # path:mtime pairs — fast to compute, sufficient when mtimes are stable.
          parts = files.map do |f|
            mtime = File.exist?(f) ? File.mtime(f).to_i.to_s : "0"
            "#{f}:#{mtime}"
          end
          require 'digest/sha2'
          Digest::SHA256.hexdigest(parts.join("\n"))
        end
      end

      # Placeholder marker stored in the objects table in place of Proc values,
      # which cannot be marshaled. The schema key is stored so that Procs can
      # be re-injected after loading from cache.
      PROC_PLACEHOLDER = :__i18n_compact_proc_placeholder__

      # Attempt to load the compacted index from a cache file.
      # Returns true if the cache was loaded successfully, false otherwise.
      def load_cache(path, fingerprint)
        return false unless File.exist?(path)

        data = File.binread(path)
        magic, version, cached_fingerprint, schema_data, value_arrays_data,
          string_table_data, objects_data, subtree_keys_data, proc_positions_data =
          Marshal.load(data)

        return false unless magic == CACHE_MAGIC
        return false unless version == CACHE_VERSION
        return false unless cached_fingerprint == fingerprint

        @schema = schema_data
        @schema_index = @schema.size
        @value_arrays = value_arrays_data
        @string_table = string_table_data.freeze
        @objects_table = objects_data
        @subtree_keys = subtree_keys_data

        @compacted_locales = {}
        @value_arrays.each_key { |locale| @compacted_locales[locale] = true }

        # Replace marker hashes in @translations so available_locales works.
        @value_arrays.each_key do |locale|
          translations[locale] = build_locale_marker
        end

        # Rebuild Proc values from .rb locale files.
        proc_positions = proc_positions_data || {}
        rebuild_procs!(proc_positions) if proc_positions.any?

        @objects_table.freeze
        true
      rescue ArgumentError, TypeError, NoMethodError, Encoding::CompatibilityError
        # Corrupt or incompatible cache — fall through to fresh compaction.
        false
      end

      # Write the compacted index to a cache file.
      def dump_cache(path, fingerprint)
        # Replace Proc values in the objects table with placeholders,
        # recording their positions so they can be rebuilt on load.
        # We work on a copy to avoid mutating the live table.
        proc_positions = {} # { objects_table_index => schema_key }
        serializable_objects = @objects_table.dup

        # Build a reverse map: for each objects_table index that holds a Proc,
        # find the schema key(s) that reference it.
        obj_idx_to_keys = {}
        @schema.each do |sym_key, schema_idx|
          @value_arrays.each do |locale, values|
            packed = values[schema_idx]
            next if packed.nil?
            if object_ref?(packed)
              oi = -(packed + 1)
              (obj_idx_to_keys[oi] ||= []) << [locale, sym_key]
            end
          end
        end

        serializable_objects.each_with_index do |obj, idx|
          if obj.is_a?(Proc)
            proc_positions[idx] = obj_idx_to_keys[idx] || []
            serializable_objects[idx] = PROC_PLACEHOLDER
          end
        end

        payload = Marshal.dump([
          CACHE_MAGIC,
          CACHE_VERSION,
          fingerprint,
          @schema,
          @value_arrays,
          @string_table,
          serializable_objects,
          @subtree_keys,
          proc_positions,
        ])

        # Atomic write: write to a temp file then rename, to avoid
        # serving a partially-written cache file to concurrent readers.
        tmp_path = "#{path}.#{Process.pid}.tmp"
        File.binwrite(tmp_path, payload)
        File.rename(tmp_path, path)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EROFS => e
        # Can't write cache (read-only filesystem, bad path, etc.) — that's OK,
        # just skip caching silently. The backend still works without it.
        File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      # Rebuild Proc values by re-loading .rb locale files and injecting
      # their Proc values back into the objects table.
      #
      # proc_positions is a Hash of { objects_table_index => [[locale, schema_key], ...] }
      # that tells us which positions in @objects_table originally held Procs
      # and which translation keys they belonged to.
      def rebuild_procs!(proc_positions)
        return if proc_positions.empty?

        # Find .rb files in the load path.
        rb_files = I18n.load_path.flatten.select { |f| f.end_with?(".rb") }
        return if rb_files.empty?

        # Load each .rb file and extract Procs by flattening the returned hash.
        rb_procs = {} # { [locale, flat_key_sym] => proc_value }
        rb_files.each do |filename|
          begin
            data = eval(IO.read(filename), binding, filename.to_s) # rubocop:disable Security/Eval
            next unless data.is_a?(Hash)

            data.each do |locale, tree|
              locale = locale.to_sym
              extract_procs(nil, tree, locale, rb_procs) if tree.is_a?(Hash)
            end
          rescue => e
            # Skip files that fail to load — they may have been removed since
            # the cache was written.
            next
          end
        end

        # Make objects_table mutable for patching.
        @objects_table = @objects_table.dup if @objects_table.frozen?

        proc_positions.each do |obj_idx, key_pairs|
          # Try to find a matching Proc from the re-loaded .rb files.
          key_pairs.each do |locale, sym_key|
            proc_val = rb_procs[[locale, sym_key]]
            if proc_val
              @objects_table[obj_idx] = proc_val
              break
            end
          end
        end
      end

      # Recursively extract Proc values from a nested hash into a flat map.
      def extract_procs(prefix, hash, locale, result)
        hash.each do |key, value|
          flat_key = prefix ? :"#{prefix}.#{key}" : key.to_s.to_sym
          case value
          when Hash
            extract_procs(flat_key, value, locale, result)
          when Proc
            result[[locale, flat_key]] = value
          end
        end
      end
    end
  end
end
