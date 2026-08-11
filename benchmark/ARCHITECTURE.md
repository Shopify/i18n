# Backend::Compact Architecture

## Overview

`I18n::Backend::Compact` is a mixin module that replaces the default deeply nested Hash tree used by `I18n::Backend::Simple` with a flat, columnar data structure backed by a binary string table. It is designed to minimize the number of Ruby heap objects and total memory consumed by translation data in long-running processes.

```ruby
I18n::Backend::Simple.include(I18n::Backend::Compact)
```

## The Problem

The Simple backend stores translations as a deeply nested Hash tree:

```
@translations = {
  en: {
    activemodel: {
      errors: {
        models: {
          user: {
            attributes: {
              email: {
                invalid: "is not a valid email",
                blank:   "can't be blank",
              }
            }
          }
        }
      }
    }
  },
  fr: { ... same structure, different leaf strings ... },
  de: { ... },
  ...
}
```

Every intermediate node is a separate `Hash` object (~430 bytes each in Ruby), and every leaf string is a separate `String` object (~40-46 bytes overhead each). With Shopify's 42 locales and 15K YAML files, this produces:

- **1.79 million Hash objects** consuming 333.5 MB
- **1.49 million String objects** consuming 177.1 MB
- **513.3 MB total retained memory**

## The Solution

After all translations are loaded, `compact!` transforms the nested tree into five flat structures:

```
                          BEFORE                                AFTER
                          ──────                                ─────

  @translations                               @schema (shared across all locales)
  ┌──────────────────────────┐                ┌─────────────────────────────────────┐
  │ en:                      │                │ :"activemodel"                => 0  │
  │   activemodel:           │                │ :"activemodel.errors"         => 1  │
  │     errors:              │                │ :"activemodel.errors.models"  => 2  │
  │       models:            │   compact!     │ :"activemodel.errors...email" => 3  │
  │         ...              │ ──────────►    │ :"activemodel...invalid"      => 4  │
  │           invalid: "..." │                │ :"activemodel...blank"        => 5  │
  │           blank: "..."   │                │ ...                                 │
  │ fr:                      │                └─────────────────────────────────────┘
  │   activemodel:           │
  │     errors:              │                @value_arrays (one store per locale)
  │       ...                │                ┌──────────────────────────────────┐
  │         invalid: "..."   │                │ en: { 0 => SUBTREE, 1 => SUBTREE,│
  │         blank: "..."     │                │       4 => 0x00000440000E,       │
  │ de:                      │                │       5 => 0x00001D0000F, ... }  │
  │   ...                    │                │ fr: DeltaStore(bits, {           │
  └──────────────────────────┘                │       4 => 0x00004C000012 })     │
                                              │ de: DeltaStore(bits, { ... })    │
  3.3M objects                                └──────────────────────────────────┘
  513 MB retained
                                                     │               │
                                                     │  decode       │  decode
                                                     ▼               ▼
                                              @string_table (single binary buffer)
                                              ┌──────────────────────────────────┐
                                              │ is not a valid emailcan't be ... │
                                              │ n'est pas un email valide...     │
                                              │ ... (all strings concatenated)   │
                                              └──────────────────────────────────┘

                                               @objects_table (shared Array)
                                               ┌──────────────────────────────────┐
                                               │ [<Array>, <Symbol>, <Proc>, ...] │
                                               └──────────────────────────────────┘

                                               @subtree_keys (parent → children index)
                                               ┌──────────────────────────────────────┐
                                               │ :"activemodel" =>                    │
                                               │   [:"activemodel.errors"]            │
                                               │ :"activemodel.errors" =>             │
                                               │   [:"activemodel.errors.models"]     │
                                               │ ...                                  │
                                               └──────────────────────────────────────┘

                                               569K objects
                                               163 MB retained
```

## Data Structures

### 1. `@schema` — Shared Key Index

A single `Hash` mapping flattened dot-separated Symbol keys to integer indices. Shared across all locales.

```ruby
{
  :"activemodel"                                     => 0,
  :"activemodel.errors"                              => 1,
  :"activemodel.errors.models"                       => 2,
  :"activemodel.errors.models.user"                  => 3,
  :"activemodel.errors.models.user.attributes"       => 4,
  :"activemodel.errors.models.user.attributes.email" => 5,
  :"activemodel...email.invalid"                     => 6,
  :"activemodel...email.blank"                       => 7,
  # ...
}
```

In the Shopify codebase: **157,079 keys**.

### 2. `@value_arrays` — Per-Locale Value Stores

A `Hash` of `{ locale => store }`. Each store is keyed by the schema index and holds only:

- **Positive integers** — packed string table references
- **Negative integers** — object table references (`-(index + 1)`)
- **`SUBTREE_SENTINEL`** (`-(1 << 62)`) — marks subtree nodes
- **An absent key** — the key does not exist in this locale

```ruby
{
  en: { 0 => SUBTREE_SENTINEL, 1 => SUBTREE_SENTINEL, 6 => 0x00000440000E, ... },
  fr: #<DeltaStore bits=..., overrides={ 6 => 0x00004C000012, ... }>,
  # ...
}
```

The store is keyed rather than positional because the schema is shared. A positional Array is sized by the union of every locale's keys, and it holds a `nil` for each key that the locale does not define. Shopify Core is about 4% dense: 813 locales over a 199,138-key schema cost 1.15 GB of Array buffer for 6.7M real entries. That padding is larger than the nested Hash tree that compaction removes.

Ruby integers up to 2^62 are **immediate values** — they consume zero heap memory. Only the store itself is allocated.

The base locale keeps a plain `Hash`. Every other locale holds a `DeltaStore`.

### 3. `DeltaStore` — Base-Locale Delta

Most of the remaining footprint is the per-(locale, key) index, not the values, and many values are byte-identical to the base locale's. Shopify Core measured 2,597,977 of 6,688,165 entries (38.8%) as identical, worth 117 MB.

A non-base locale therefore stores two things:

- **`@bits`** — a presence bitmap over the schema, one bit per schema index
- **`@overrides`** — a `Hash` of only the schema indices whose value differs from the base locale's

`DeltaStore#[]` reads the bit first:

- The bit is clear: the locale does not define the key, so the result is `nil`.
- The bit is set and an override exists: the result is the override.
- The bit is set and no override exists: the result is the base locale's value.

The bitmap is load-bearing, not an optimisation. Without it, "same as base" and "not defined here" collapse into the same absence, and an untranslated key resolves to the base value. That is wrong for an application whose fallback chain excludes the base locale. Shopify Core sets `config.i18n.fallbacks = [nil]` and raises on a missing translation.

`apply_base_delta!` runs at the end of `compact!`. It returns early once any store is a `DeltaStore`, because `compact!` runs again on every `eager_load!`. The public `delta_stats` reader reports `{ base:, total:, inherited: }`.

### 4. `@string_table` — Binary String Buffer

A single frozen `String` with `Encoding::BINARY` containing all unique translation strings concatenated end-to-end. Strings are deduplicated during building — identical content with the same encoding is stored once.

```
Offset 0          68            150           ...
┌─────────────────┬─────────────┬─────────────┬───
│ is not a valid  │ can't be    │ n'est pas   │
│ email           │ blank       │ un email... │
└─────────────────┴─────────────┴─────────────┴───
```

In the Shopify codebase: **90.6 MB**, holding 1,490,916 unique strings serving 2,774,778 references (1.9x dedup ratio).

### 5. `@objects_table` — Non-String Value Array

A shared frozen `Array` holding all non-string leaf values: Arrays (e.g., day names), Symbols (link targets), Procs, booleans, numbers. Referenced from the value stores by negative index.

In the Shopify codebase: only **308 entries**. Nearly all translations are strings.

### 6. `@subtree_keys` — Subtree Children Index

A frozen `Hash` mapping each parent key to its direct children's schema keys. Used only for subtree reconstruction when `I18n.t(:some_namespace)` returns a Hash.

```ruby
{
  :"activemodel"        => [:"activemodel.errors"],
  :"activemodel.errors" => [:"activemodel.errors.models"],
  # ...
}
```

## Packed Integer Format

String references are packed into a single positive integer to avoid allocating any objects:

```
 Bit 63          55          52          16           0
 ┌──────────────┬───────────┬───────────┬────────────┐
 │   (unused)   │ enc_id    │  offset   │   length   │
 │   8 bits     │ 4 bits    │  36 bits  │  16 bits   │
 └──────────────┴───────────┴───────────┴────────────┘

 packed = (encoding_id << 52) | (offset << 16) | length
```

| Field | Bits | Max Value | Purpose |
|---|---|---|---|
| `encoding_id` | 4 | 15 | Encoding of the original string (0=UTF-8, 1=ASCII, 2=Binary) |
| `offset` | 36 | 64 GB | Byte offset into `@string_table` |
| `length` | 16 | 65,535 | Byte length of the string |

The total packed value fits within 56 bits, well under Ruby's 62-bit Fixnum limit (immediate value, zero heap allocation). Strings longer than 65,535 bytes fall back to the objects table.

## Lookup Path

### Leaf Lookup (common case) — O(1)

```
I18n.t("activemodel.errors.models.user.attributes.email.invalid", locale: :en)
│
├─ 1. Flatten key + strip locale prefix
│     "activemodel.errors.models.user.attributes.email.invalid"
│
├─ 2. Schema lookup: @schema[:"activemodel...email.invalid"] → idx 6
│     (one Hash lookup)
│
├─ 3. Value store lookup: @value_arrays[:en][6] → 0x00000440000E
│     (one Hash lookup, or a bitmap test plus one Hash lookup)
│
├─ 4. Detect positive integer → string reference
│
├─ 5. Unpack: offset=68, length=14, encoding_id=0(UTF-8)
│
├─ 6. Slice: @string_table.byteslice(68, 14)
│     → "is not a valid"
│
└─ 7. Force encoding: str.force_encoding(Encoding::UTF_8)
       → "is not a valid email"
```

### Subtree Lookup (rare) — O(children)

```
I18n.t("activemodel.errors", locale: :en)
│
├─ 1. Schema lookup → idx, value = SUBTREE_SENTINEL
│
├─ 2. Look up children: @subtree_keys[:"activemodel.errors"]
│     → [:"activemodel.errors.models", ...]
│
├─ 3. Recursively reconstruct nested Hash from children
│     (each child is either another subtree or a decoded leaf)
│
└─ 4. Return: { models: { user: { attributes: { email: { ... } } } } }
```

## Lifecycle

```
                    ┌─────────────────────┐
                    │   Backend created    │
                    │   (Simple mode)      │
                    └──────────┬──────────┘
                               │
       configure_compact_cache(path: "...")
                               │
          eager_load!, or the first lookup or
          available_locales call — whichever
          reaches init_translations first
                               │
                  ┌────────────┴────────────┐
                  │ compute fingerprint     │
                  │ from load_path files,   │
                  │ or call fingerprint:    │
                  └────────────┬────────────┘
                               │
                ┌──────────────┴──────────────┐
                │  Cache file exists           │
                │  and fingerprint matches?    │
                └──────┬──────────────┬───────┘
                  yes  │              │  no
                       ▼              ▼
          ┌──────────────────┐  ┌──────────────────┐
          │  serializer.load │  │  load_translations│
          │  cache file      │  │  (parse all YAML) │
          │                  │  └────────┬─────────┘
          │  Rebuild procs   │           │
          │  from .rb files  │      compact!
          └────────┬─────────┘           │
                   │              ┌──────┴──────┐
                   │              │ dump_cache  │
                   │              │ to file     │
                   │              └──────┬──────┘
                   │                     │
                   └──────────┬──────────┘
                              ▼
                   ┌─────────────────────┐
                   │   Compacted mode    │
                   │   (columnar index)  │◄─────────────────┐
                   └──────────┬──────────┘                  │
                              │                             │
                    store_translations          rebuild_nested_tree!
                   (decompacts one locale)     (per-locale, on demand)
                              │                             │
                              ├─────────────────────────────┘
                              │
                       reload!│
                              ▼
                   ┌─────────────────────┐
                   │  All state cleared  │
                   │  (back to start)    │
                   └─────────────────────┘
```

### Key behaviors

- **`configure_compact_cache(path: "...", digest: false, serializer: Marshal, fingerprint: nil)`** configures the compact cache. When configured, the backend loads the cache file instead of parsing YAML on a cache hit, and writes the cache on a miss. The `digest:` option controls cache invalidation: `false` (default) uses file mtimes, `true` uses SHA256 content digests. The `serializer:` option replaces `Marshal`; it must respond to `dump` and `load`, and `configure_compact_cache` raises `ArgumentError` when it does not. The `fingerprint:` option takes a callable returning a String, for a host that already computes a load-path digest and should not pay for a second one.
- **`init_translations`** is where the cache is served. `Backend::Simple` calls it from `lookup` and from `available_locales`, so one `I18n.t` during boot parses the whole load path before `eager_load!` is ever reached. Hooking here means the cache serves whatever triggers the load, whenever that happens, which is why `I18nCache`-style caches sit at this level. Shopify Core measured 13,980 ms of loading escaping an `eager_load!`-only hook, with the cache then loading on top of it rather than instead of it.
- **`eager_load!`** calls `super`, which reaches `init_translations` and so the cache. On a hit there is nothing left to do. On a miss it compacts and writes the cache, reusing the fingerprint `init_translations` already computed.
- **`compact!`** is idempotent — calling it again when nothing changed is a no-op. If new translations were added since the last compaction, it rebuilds everything from scratch (since packed integer references can't be incrementally merged). It consults the cache only while no `store_translations` call has decompacted a locale: the fingerprint covers load_path files alone, so a warm cache would otherwise replace a programmatic write with the cached value.
- **`store_translations`** after compaction decompacts only the affected locale by calling `rebuild_nested_tree!`, which reconstitutes the nested Hash from the flat index. The other locales remain compacted. It also marks the backend dirty, which is what sends the next `compact!` down the full rebuild path instead of the cache.
- **`reload!`** clears all compacted state and resets to uninitialized.
- **`lookup`** checks `@compacted_locales` to decide whether to use the fast columnar path or fall through to the Simple backend's nested Hash traversal.
- **`delta_stats`** reports how many entries `apply_base_delta!` elided. It is `nil` before compaction.

## Caching

The compacted representation can be serialized to a compact cache file so that subsequent boots skip YAML parsing and compaction entirely:

```ruby
I18n.backend.configure_compact_cache(path: "/tmp/i18n_compact.cache")
I18n.backend.eager_load!
```

### Cache file format

The file is a plain header followed by one serialized payload:

```
┌──────────────┬─────────────┬──────────────────────────────────────┐
│ magic        │ version     │ payload                              │
│ "I18NC"      │ uint32 BE   │ serializer.dump(Hash)                │
│ 5 bytes      │ 4 bytes     │ rest of the file                     │
└──────────────┴─────────────┴──────────────────────────────────────┘
```

The header sits outside the payload so that the magic bytes and the version are checked before any byte reaches the serializer. A file written by a different serializer fails the header check and is discarded, instead of raising from inside third-party parsing code.

The payload is a Hash:

| Key | Type | Description |
|---|---|---|
| `:fingerprint` | String | SHA256 hex digest for cache invalidation |
| `:schema` | Hash | `{ Symbol => Integer }` — shared key index |
| `:base_locale` | Symbol | The locale every delta store resolves through, or `nil` |
| `:value_stores` | Hash | `{ Symbol => Array }` — one tagged store per locale |
| `:string_table` | String | Binary buffer of concatenated translation strings |
| `:objects_table` | Array | Non-string values (with Procs replaced by placeholders) |
| `:subtree_keys` | Hash | `{ Symbol => Array<Symbol> }` — parent→children index |
| `:proc_positions` | Hash | `{ Integer => [[locale, key], ...] }` — where Procs were |

Each entry in `:value_stores` is tagged, so a store travels as plain data rather than as an object:

```ruby
[0, { schema_index => packed, ... }]                  # a plain Hash store
[1, bits, { schema_index => packed, ... }, inherited] # a DeltaStore
```

### Serializers

`Marshal` is the default. Any object responding to `dump(object)` and `load(payload)` can replace it, which is the interface a Paquito codec already has:

```ruby
codec = Paquito::CodecFactory.build([Symbol])
I18n.backend.configure_compact_cache(path: path, serializer: codec)
```

The payload holds only `Hash`, `Array`, `String`, `Symbol`, `Integer` and `nil`, plus whatever non-string translation values the objects table carries. A serializer therefore needs no knowledge of this backend's classes.

Tagging the stores is what makes that true, and it is also a correctness requirement rather than a tidiness one. A `DeltaStore` references the base locale's store, and `Marshal` is the only serializer here that restores such sharing on load. MessagePack, and so Paquito, writes a copy at each reference, which would give all 813 locales their own copy of the base store — exactly the memory the delta removes. The backend therefore writes the base store once and re-shares it across every delta locale on load.

Two further properties keep an arbitrary serializer safe:

- **A frozen result is allowed.** `Paquito::CodecFactory.build(types, freeze: true)` returns frozen containers, so `compact!` reassigns `@schema`, `@value_arrays` and `@compacted_locales` when it rebuilds instead of clearing them in place.
- **A failed load changes nothing.** `load_compact_cache` validates every field and rebuilds the stores before it assigns any state, and it replaces the nested trees with locale markers last. A rejected or malformed payload therefore leaves the live translations in place for the fresh compaction, and any exception the serializer raises becomes a plain cache miss.

### Cache invalidation

Three modes. The first two are selected via the `digest:` option:

**Mtime-based (default):** Hashes sorted file paths + their `File.mtime` values. Fast to compute (~ms), but won't survive mtime resets (e.g., `git checkout`, `rsync --archive`).

```ruby
I18n.backend.configure_compact_cache(path: path)
I18n.backend.eager_load!
```

**Content-based:** Hashes sorted file paths + `File.read` contents via SHA256. Slower to compute (reads all files) but robust across deploys.

```ruby
I18n.backend.configure_compact_cache(path: path, digest: true)
I18n.backend.eager_load!
```

**Host-supplied:** A callable passed as `fingerprint:` replaces both. The built-in SHA256 pass sits on the critical path of every boot, including the warm ones the cache exists to make fast: Shopify Core measured it at 4.1 s warm and 15.6 s with a cold page cache. Core already computes an equivalent digest, so it passes that instead and pays for one rather than two. Swapping SHA256 for `I18nCache.digest` took the precompile boot from 15,554 ms to 1,763 ms of fingerprinting.

```ruby
I18n.backend.configure_compact_cache(path: path, fingerprint: -> { I18nCache.digest })
I18n.backend.eager_load!
```

### Proc handling

Proc values (primarily pluralization rules from `.rb` locale files) cannot be serialized with Marshal. The cache system handles this by:

1. **On write:** Replacing each Proc in the objects table with a `PROC_PLACEHOLDER` marker and recording its position + associated schema keys in `proc_positions`.
2. **On load:** Re-evaluating all `.rb` files from `I18n.load_path`, extracting Procs by flattening the returned hashes, and patching them back into the objects table at the recorded positions.

This means `.rb` locale files are always re-evaluated on cache load (they're typically small — e.g., pluralization rules), while the expensive YAML parsing (261 MB across 15K files) is skipped entirely.

## Memory Model

Why this saves memory — a Ruby object-level view:

```
Simple backend (per-locale, per intermediate key):
┌────────────────────────────────────────────────────────────────┐
│  Hash object:   40 bytes (RValue) + ~200-400 bytes (st_table) │
│  String object: 40 bytes (RValue) + N bytes (heap buffer)     │
│  × 1.79M hashes + 1.49M strings = 510 MB                     │
└────────────────────────────────────────────────────────────────┘

Compact backend:
┌────────────────────────────────────────────────────────────────┐
│  @schema:        1 Hash (14 MB for 157K symbol→int pairs)     │
│  @value_arrays:  42 value stores of integers (47 MB total)    │
│                  (integers are immediate values — 0 bytes each │
│                   on the heap; only the store itself)         │
│  @string_table:  1 String (90.6 MB, one contiguous buffer)    │
│  @objects_table: 1 Array (308 entries, 139 KB)                │
│  @subtree_keys:  1 Hash (10.9 MB for parent→children map)    │
│  Total: 163 MB                                                │
└────────────────────────────────────────────────────────────────┘
```

The `@value_arrays` figure above comes from the 42-locale Shopify benchmark, which ran before the sparse-store and base-locale delta changes.

The key insight: Ruby's per-object overhead (~40 bytes for the RValue + type-specific backing storage) dominates when you have millions of small objects. Replacing 3.3 million objects with ~50 large ones eliminates most of this overhead.

## Files

| File | Purpose |
|---|---|
| `lib/i18n/backend/compact.rb` | Implementation (module, ~600 lines) |
| `lib/i18n/backend.rb` | `autoload :Compact` entry |
| `test/backend/compact_test.rb` | Unit tests (57 tests, including cache and serializer tests) |
| `test/api/compact_test.rb` | API integration tests (143 tests, all standard I18n::Tests modules) |
| `benchmark/memory.rb` | Synthetic memory benchmark |
| `benchmark/shopify_memory.rb` | Real Shopify files memory benchmark (includes cache) |
| `benchmark/RESULTS.md` | Benchmark results |
| `benchmark/ARCHITECTURE.md` | This document |
