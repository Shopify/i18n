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
# 3. **Sparse integer-packed value stores**: Each locale's values are keyed by
#    the shared schema index and hold only immediate-value Integers, nil, or a
#    sentinel marker. String translations are encoded as packed integers:
#    `(offset << 16) | length`, where offset and length index into the binary
#    string table. Non-string values (Arrays, Symbols, Procs, etc.) are stored
#    in a shared side table and referenced by negative integers.
#
#    The store is keyed rather than positional because the schema is shared: a
#    positional Array is sized by the union of every locale's keys and nil-padded
#    for each key a locale does not define. On Shopify Core (813 locales over a
#    199,138-key schema, ~4% dense) that padding cost 1.15 GB of Array buffer for
#    6.7M real entries — more than the nested Hash tree it replaced, so
#    compaction made Core's footprint worse rather than better.
#
# 4. **Base-locale deltas**: A locale stores only the values that differ from
#    the base locale's, plus a presence bitmap over the schema. Core measured
#    38.8% of entries as byte-identical to the base. The bitmap keeps "same as
#    base" distinguishable from "not defined here", so this never invents a
#    fallback where the application has none.
#
# 5. **Reduced object count**: The deeply nested Hash tree (thousands of
#    intermediate Hash objects and String objects) is replaced with a single
#    schema Hash + one value store per locale + one binary buffer + one side
#    table.
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
# == Compact Cache
#
# The compacted representation can be serialized to a compact cache file
# so that subsequent boots skip YAML parsing and compaction entirely.
# Configure the compact cache before calling eager_load!:
#
#   I18n.backend.configure_compact_cache(path: "/tmp/i18n_compact.cache")
#   I18n.backend.eager_load!
#
# Or with content-based cache invalidation (slower to compute but survives
# mtime resets during deploys):
#
#   I18n.backend.configure_compact_cache(path: "/tmp/i18n_compact.cache", digest: true)
#   I18n.backend.eager_load!
#
# The compact cache is invalidated automatically when the set of load_path
# files or their contents/mtimes change.
#
# Proc values (e.g., pluralization rules from .rb locale files) cannot be
# serialized. When loading from the compact cache, .rb locale files are
# re-evaluated to reconstruct any Proc values.
#
# == Cache serializers
#
# The cache payload is encoded with Marshal by default. Any object that
# responds to #dump(object) and #load(payload) can replace it, which lets an
# application use a faster or safer codec, such as Paquito:
#
#   codec = Paquito::CodecFactory.build([Symbol])
#   I18n.backend.configure_compact_cache(path: path, serializer: codec)
#
# The payload holds only Hash, Array, String, Symbol, Integer and nil, plus
# whatever non-string translation values the objects table carries, so a
# serializer needs no knowledge of this backend's classes. In particular the
# per-locale delta stores travel as plain data: they reference the base
# locale's store, and only Marshal would restore that sharing on load, so the
# backend re-shares one base store itself.
#
# The magic bytes and the format version sit in a plain header outside the
# payload, so a cache written by a different serializer is rejected by the
# header check instead of raising from inside the serializer.
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
      # Configure the compact cache. When a path is configured, eager_load!
      # and compact! will attempt to load the compacted index from the cache
      # file (skipping YAML parsing entirely on cache hit), and will write
      # the cache file after compaction on cache miss.
      #
      # Options:
      #   path:        Path to a compact cache file.
      #   digest:      When true, use SHA256 content digests for cache
      #                invalidation instead of file mtimes. Slower to compute
      #                but survives mtime resets (e.g., during deploys).
      #                Defaults to false.
      #   serializer:  Object responding to #dump(object) and #load(payload),
      #                used to encode the cache payload. Defaults to Marshal.
      #                See "Cache serializers" in the module documentation.
      #   fingerprint: Callable returning a String, for hosts that already
      #                compute a load-path digest and should not pay for a
      #                second one. Shopify Core measured the built-in SHA256
      #                content digest at 4.1s warm and 15.6s with a cold page
      #                cache, which on its own can cost more than the load the
      #                cache is meant to avoid.
      def configure_compact_cache(path:, digest: false, serializer: Marshal, fingerprint: nil)
        unless serializer.respond_to?(:dump) && serializer.respond_to?(:load)
          raise ArgumentError, "compact cache serializer must respond to #dump and #load, got #{serializer.inspect}"
        end

        @compact_cache_path = path
        @compact_cache_digest = digest
        @compact_cache_serializer = serializer
        @compact_cache_fingerprint = fingerprint
      end

      # Trigger compaction after eager loading. If a compact cache has been
      # configured via configure_compact_cache, it will be used to skip
      # YAML parsing on cache hit.
      def eager_load!
        super()
        compact!(_fingerprint: @_compact_cache_fingerprint)
      end

      # Compact all loaded translations into an optimized columnar structure
      # backed by a binary string table.
      #
      # This should be called after all translations have been loaded (e.g.,
      # after `eager_load!` in production). If a compact cache has been
      # configured via configure_compact_cache, it will be used.
      def compact!(_fingerprint: nil)
        init_translations unless initialized?

        @compacted_locales ||= {}
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}

        # Check if any locales need compaction.
        has_pending = translations.any? { |locale, _| !@compacted_locales[locale] }

        # Nothing to do if all locales are already compacted.
        return if !has_pending

        # Try loading from compact cache if configured.
        #
        # Skipped once store_translations has decompacted a locale. The
        # fingerprint covers only load_path files, so a programmatic write is
        # invisible to it: the cache still matches, and loading it would
        # silently replace the write with the cached value.
        if @compact_cache_path && !@compact_dirty
          fingerprint = _fingerprint || compute_compact_cache_fingerprint
          if load_compact_cache(fingerprint)
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

        # Reset the compacted state — we'll rebuild all locales. These are
        # reassigned rather than cleared because a cache load can hand back
        # frozen containers: Paquito freezes its result when built with
        # freeze: true, and clearing one of those raises.
        @schema = {}
        @schema_index = 0
        @value_arrays = {}
        @compacted_locales = {}
        @subtree_children = {}

        # Build fresh string and object tables.
        @_string_builder = StringTableBuilder.new
        @_objects_builder = []

        translations.each do |locale, tree|
          compact_locale!(locale, tree)
        end

        # Finalize the string table into a single frozen binary buffer.
        @string_table = @_string_builder.to_buffer
        @objects_table = @_objects_builder.freeze

        # Clean up builders — they're no longer needed.
        @_string_builder = nil
        @_objects_builder = nil

        # Build the subtree key sets for efficient subtree reconstruction.
        build_subtree_index!

        # Keep only the values that differ from the base locale's.
        apply_base_delta!

        # Every locale is compacted from the live tree again, so the state
        # matches what the cache below is about to hold.
        @compact_dirty = false

        # Write compact cache for next boot.
        if @compact_cache_path
          fingerprint ||= compute_compact_cache_fingerprint
          dump_compact_cache(fingerprint)
        end
      end

      def store_translations(locale, data, options = EMPTY_HASH)
        locale = locale.to_sym

        # If this locale was compacted, we need to rebuild the nested tree
        # from the flat index so that the new data can be deep-merged in.
        if @compacted_locales&.dig(locale)
          rebuild_nested_tree!(locale)

          # The live tree now differs from the cache. Recorded here rather than
          # inferred from @compacted_locales, which rebuild_nested_tree! empties
          # when the cache holds a single locale.
          @compact_dirty = true
        end

        super
      end

      def reload!
        @schema = nil
        @schema_index = nil
        @value_arrays = nil
        @compacted_locales = nil
        @subtree_children = nil
        @delta_stats = nil
        @_compact_cache_fingerprint = nil
        @string_table = nil
        @objects_table = nil
        @_string_builder = nil
        @_objects_builder = nil
        @compact_dirty = nil
        super
      end

      # Entries elided because they matched the base locale, and the totals
      # behind that: { base:, total:, inherited: }. nil before compaction.
      attr_reader :delta_stats

      protected

      # Serve the compact cache from init_translations rather than eager_load!.
      #
      # eager_load! is too late to be the only hook. Backend::Simple calls
      # init_translations from `lookup` and from `available_locales`, so a single
      # I18n.t during boot — one constant defined as a translated string is
      # enough — parses the whole load path before eager_load! is ever reached.
      # Shopify Core measured 13,980 ms of loading happening that way, with the
      # compact cache then loading on top of it rather than instead of it.
      #
      # Hooking here means the cache serves whatever triggers the load, whenever
      # it happens, which is why I18nCache-style caches sit at this level.
      def init_translations
        if @compact_cache_path
          @_compact_cache_fingerprint ||= compute_compact_cache_fingerprint
          if load_compact_cache(@_compact_cache_fingerprint)
            @initialized = true
            return
          end
        end

        super
      end

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

      # A locale's value store: the values that differ from the base locale's,
      # plus a presence bitmap over the schema.
      #
      # Most of the footprint is the per-(locale, key) index rather than the
      # values themselves, and a large share of values are byte-identical to the
      # base locale's. Shopify Core measured 2,597,977 of 6,688,165 entries
      # (38.8%) as identical.
      #
      # The bitmap is what keeps this honest. Without it, "same as base" and "not
      # defined for this locale" become indistinguishable, which would invent a
      # base-locale fallback for applications that deliberately have none.
      # Responds to #[] so every read site treats it like the Hash it replaces.
      class DeltaStore
        # bits and base are read by the cache serializer, which writes a delta
        # store as plain data and re-shares one base store across every locale
        # on load.
        attr_reader :bits, :overrides, :base, :inherited_count

        def initialize(bits, overrides, base, inherited_count)
          @bits = bits
          @overrides = overrides
          @base = base
          @inherited_count = inherited_count
        end

        def [](schema_index)
          return nil if schema_index.nil?

          byte = @bits.getbyte(schema_index >> 3)
          return nil if byte.nil? || (byte & (1 << (schema_index & 7))).zero?

          value = @overrides[schema_index]
          return value unless value.nil?

          @base[schema_index]
        end

        def size
          @overrides.size + @inherited_count
        end
      end

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
      #
      # US-ASCII strings are normalized to UTF-8 for dedup purposes since
      # US-ASCII is a strict subset of UTF-8 with identical byte representation.
      # This avoids storing the same bytes twice under different encoding tags.
      class StringTableBuilder
        def initialize
          @buffer = String.new(encoding: Encoding::BINARY, capacity: 4096)
          @index = {}  # [bytes, encoding_id] => [offset, length, encoding_id]
        end

        # Add a string to the table, returning [offset, length, encoding_id].
        # Deduplicates by byte content + encoding.
        def add(str)
          # Normalize US-ASCII to UTF-8 — identical bytes, saves dedup space.
          enc = str.encoding
          enc_id = encoding_id(enc)

          key = [str, enc_id]
          existing = @index[key]
          return existing if existing

          offset = @buffer.bytesize
          length = str.bytesize
          @buffer << str.b  # append as binary

          entry = [offset, length, enc_id].freeze
          @index[key] = entry
          entry
        end

        # Finalize the buffer into a frozen binary string.
        def to_buffer
          @buffer.freeze
        end

        private

        def encoding_id(encoding)
          case encoding
          # Normalize US-ASCII → UTF-8 (identical byte representation).
          when Encoding::UTF_8, Encoding::US_ASCII then ENCODING_UTF8
          when Encoding::BINARY                    then ENCODING_BINARY
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

      # Replace every non-base locale's store with a presence bitmap plus only
      # the values that differ from the base locale's.
      def apply_base_delta!
        stores = @value_arrays
        return if stores.nil? || stores.empty?

        # Only the base locale keeps a plain Hash, so "some store is a Hash"
        # stays true after a successful pass. compact! runs again on every
        # eager_load!, and a second pass would convert nothing while still
        # overwriting the recorded stats.
        return if stores.each_value.any? { |store| store.is_a?(DeltaStore) }
        return unless stores.each_value.any? { |store| store.is_a?(Hash) }

        base_locale = I18n.default_locale&.to_sym
        base = stores[base_locale]
        total = stores.each_value.sum(&:size)

        unless base.is_a?(Hash)
          @delta_stats = { base: nil, total: total, inherited: 0 }
          return
        end

        bitmap_bytes = (@schema.size / 8) + 1
        inherited = 0

        stores.each do |locale, store|
          next if locale == base_locale
          next unless store.is_a?(Hash)

          bits = String.new("\0" * bitmap_bytes, encoding: Encoding::BINARY)
          overrides = {}
          local_inherited = 0

          store.each do |idx, packed|
            byte_index = idx >> 3
            bits.setbyte(byte_index, (bits.getbyte(byte_index) || 0) | (1 << (idx & 7)))
            if base[idx] == packed
              local_inherited += 1
            else
              overrides[idx] = packed
            end
          end

          inherited += local_inherited
          stores[locale] = DeltaStore.new(bits.freeze, overrides.freeze, base, local_inherited).freeze
        end

        @delta_stats = { base: base_locale, total: total, inherited: inherited }
      end

      # Compact a single locale's translation tree into the columnar structure.
      def compact_locale!(locale, tree)
        @schema ||= {}
        @schema_index ||= 0
        @value_arrays ||= {}
        @compacted_locales ||= {}
        @subtree_children ||= {}

        values = {}
        flatten_into_columns(nil, tree, values)

        @value_arrays[locale] = values
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
          segment = key.is_a?(Symbol) ? key : key.to_s.to_sym
          flat_key = prefix ? :"#{prefix}.#{key}" : key.to_s.to_sym

          # Get or create the schema index for this key.
          idx = @schema[flat_key]
          unless idx
            idx = @schema_index
            @schema[flat_key] = idx
            @schema_index += 1
            (@subtree_children[prefix] ||= []) << segment
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
      # Parent/child links are recorded while flattening, so there is nothing to
      # recover here.
      #
      # Each parent holds only its children's own segments. A reader rebuilds a
      # child's flat key by joining, which is the same operation flattening
      # performed, so it is exact where splitting was a guess. Storing the child
      # key alongside the segment was measured and rejected: on a 124k-key
      # corpus it made this index 12.0 MB rather than 8.4 MB, buying 35% faster
      # subtree reads and 49% faster decompaction, both rare paths.
      #
      # They used to be recovered by splitting each flat key on its last dot,
      # which silently mis-parses any key that contains the separator. Shopify
      # Core has `template_names: { "Robots.txt" => ... }`: the flat key
      # `...template_names.Robots.txt` is indistinguishable from a nested
      # `Robots` -> `txt`, so an intermediate node was invented and
      # `I18n.t(:template_names)` came back without the entry, where
      # Backend::Simple returns it.
      def build_subtree_index!
        @subtree_children.each_value(&:freeze)
        @subtree_children.freeze
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
        children = @subtree_children[parent_key]
        return {} unless children

        values = @value_arrays[locale]
        result = {}

        children.each do |segment|
          child_key = parent_key ? :"#{parent_key}.#{segment}" : segment
          packed = values[@schema[child_key]]
          next if packed.nil?

          result[segment] = if subtree_marker?(packed)
            reconstruct_subtree(locale, child_key)
          else
            decode_value(packed)
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
        rebuild_node(nil, values, nested)
        translations[locale] = nested
      end

      # Walk the recorded parent/child links rather than splitting flat keys,
      # for the same reason build_subtree_index! no longer splits them: a key
      # containing the separator would otherwise be scattered across invented
      # parent nodes on the way back out.
      def rebuild_node(parent_key, values, target)
        children = @subtree_children[parent_key]
        return unless children

        children.each do |segment|
          child_key = parent_key ? :"#{parent_key}.#{segment}" : segment
          packed = values[@schema[child_key]]
          next if packed.nil?

          if subtree_marker?(packed)
            child = {}
            rebuild_node(child_key, values, child)
            target[segment] = child unless child.empty?
          else
            target[segment] = decode_value(packed)
          end
        end
      end

      # ================================================================
      # Cache serialization
      # ================================================================

      # The cache file is framed with a plain header, written outside the
      # serialized payload, so that the magic bytes and the format version can
      # be checked before any byte reaches the serializer. A file written by a
      # different serializer then fails the header check and is discarded,
      # rather than raising from inside third-party parsing code.
      CACHE_MAGIC   = "I18NC"
      CACHE_VERSION = 1
      CACHE_HEADER_FORMAT = "a5N"
      CACHE_HEADER_SIZE = 9

      # Tags for the serialized form of a locale's value store.
      #
      # A DeltaStore holds a reference to the base locale's store, and only
      # Marshal restores that sharing on load. A serializer that copies instead
      # (MessagePack, and so Paquito) would give every locale its own copy of
      # the base store, which is exactly the memory the delta removes. The
      # stores therefore travel as plain data, and load re-shares one base
      # store across every delta locale.
      STORE_PLAIN = 0
      STORE_DELTA = 1

      # Compute a fingerprint of all load_path files for compact cache
      # invalidation.
      #
      # When @compact_cache_digest is false (default), uses file paths +
      # mtimes. This is fast but won't survive mtime resets (e.g., git
      # checkout, rsync, deploy).
      #
      # When @compact_cache_digest is true, uses SHA256 of file contents.
      # Slower but robust across deploys.
      def compute_compact_cache_fingerprint
        return @compact_cache_fingerprint.call.to_s if @compact_cache_fingerprint

        files = I18n.load_path.flatten.sort
        if @compact_cache_digest
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

      # The configured serializer, or Marshal when none was configured.
      def compact_cache_serializer
        @compact_cache_serializer || Marshal
      end

      # Attempt to load the compacted index from the compact cache file.
      # Returns true if the compact cache was loaded successfully, false otherwise.
      def load_compact_cache(fingerprint)
        return false unless @compact_cache_path && File.exist?(@compact_cache_path)

        payload = File.open(@compact_cache_path, "rb") do |file|
          header = file.read(CACHE_HEADER_SIZE)
          break nil unless header && header.bytesize == CACHE_HEADER_SIZE

          magic, version = header.unpack(CACHE_HEADER_FORMAT)
          break nil unless magic == CACHE_MAGIC && version == CACHE_VERSION

          compact_cache_serializer.load(file.read)
        end

        return false unless payload.is_a?(Hash)
        return false unless payload[:fingerprint] == fingerprint

        # Validate and rebuild everything before assigning any state, so an
        # unusable payload leaves the backend untouched and falls through to
        # fresh compaction. A half-assigned backend would survive the rescue
        # below and reach compact! as a mix of cached and live state.
        schema         = payload[:schema]
        string_table   = payload[:string_table]
        objects_table  = payload[:objects_table]
        subtree_children = payload[:subtree_children]
        proc_positions = payload[:proc_positions] || {}

        return false unless schema.is_a?(Hash)
        return false unless string_table.is_a?(String)
        return false unless objects_table.is_a?(Array)
        return false unless subtree_children.is_a?(Hash)
        return false unless proc_positions.is_a?(Hash)

        value_arrays = restore_value_stores(payload[:value_stores], payload[:base_locale])
        return false unless value_arrays

        @schema = schema
        @schema_index = schema.size
        @value_arrays = value_arrays
        @string_table = force_binary(string_table).freeze
        @objects_table = objects_table
        @subtree_children = subtree_children

        # Rebuild Proc values from .rb locale files.
        rebuild_procs!(proc_positions) if proc_positions.any?
        @objects_table.freeze

        @compacted_locales = {}
        @value_arrays.each_key { |locale| @compacted_locales[locale] = true }

        # Last, because this is the one step that discards live state: the
        # nested trees are replaced by markers so available_locales still sees
        # every locale. Anything that raises above still leaves the real
        # translations in place for the fresh compaction to use.
        @value_arrays.each_key do |locale|
          translations[locale] = build_locale_marker
        end

        true
      rescue StandardError
        # Corrupt or incompatible cache — fall through to fresh compaction.
        # The exception classes a serializer raises are its own, so this cannot
        # enumerate them without coupling to one implementation.
        false
      end

      # Rebuild the per-locale stores from their plain serialized form, wiring
      # every delta store to the one shared base store. Returns nil when the
      # payload is inconsistent, which discards the cache.
      def restore_value_stores(data, base_locale)
        return nil unless data.is_a?(Hash)

        stores = {}
        base = nil

        # The base store must exist before any delta store can reference it.
        if base_locale
          tag, plain = data[base_locale]
          return nil unless tag == STORE_PLAIN

          base = plain
          stores[base_locale] = base
        end

        data.each do |locale, entry|
          next if locale == base_locale

          case entry[0]
          when STORE_DELTA
            return nil unless base

            _tag, bits, overrides, inherited_count = entry
            stores[locale] = DeltaStore.new(
              force_binary(bits).freeze, overrides.freeze, base, inherited_count
            ).freeze
          when STORE_PLAIN
            stores[locale] = entry[1]
          else
            return nil
          end
        end

        stores
      end

      # The string table and the delta bitmaps are byte buffers. Marshal keeps
      # their BINARY encoding, but a serializer only has to return the same
      # bytes, so retag rather than trust the tag it came back with.
      def force_binary(str)
        return str if str.encoding == Encoding::BINARY

        str = str.dup if str.frozen?
        str.force_encoding(Encoding::BINARY)
      end

      # The locale whose store every delta store resolves through, found by
      # identity so it holds regardless of what delta_stats recorded.
      def delta_base_locale
        delta = @value_arrays.each_value.find { |store| store.is_a?(DeltaStore) }
        return nil unless delta

        base = delta.base
        @value_arrays.each { |locale, store| return locale if store.equal?(base) }
        nil
      end

      # The per-locale stores as plain data: a Hash for the base locale, and
      # [tag, bits, overrides, inherited_count] for every delta locale.
      def serializable_value_stores
        stores = {}

        @value_arrays.each do |locale, store|
          stores[locale] = if store.is_a?(DeltaStore)
            [STORE_DELTA, store.bits, store.overrides, store.inherited_count]
          else
            [STORE_PLAIN, store]
          end
        end

        stores
      end

      # Write the compacted index to the compact cache file.
      def dump_compact_cache(fingerprint)
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

        payload = {
          :fingerprint    => fingerprint,
          :schema         => @schema,
          :base_locale    => delta_base_locale,
          :value_stores   => serializable_value_stores,
          :string_table   => @string_table,
          :objects_table  => serializable_objects,
          :subtree_children => @subtree_children,
          :proc_positions => proc_positions,
        }
        serialized = compact_cache_serializer.dump(payload)

        # Ensure the parent directory exists.
        require 'fileutils'
        FileUtils.mkdir_p(File.dirname(@compact_cache_path))

        # Atomic write: write to a temp file then rename, to avoid
        # serving a partially-written compact cache file to concurrent readers.
        # The header is written separately so that framing it costs no copy of
        # the payload, which is the largest allocation in the process.
        tmp_path = "#{@compact_cache_path}.#{Process.pid}.tmp"
        File.open(tmp_path, "wb") do |file|
          file.write([CACHE_MAGIC, CACHE_VERSION].pack(CACHE_HEADER_FORMAT))
          file.write(serialized)
        end
        File.rename(tmp_path, @compact_cache_path)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EROFS
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
          rescue
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
