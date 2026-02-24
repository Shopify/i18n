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
  │     errors:              │                @value_arrays (one per locale)
  │       ...                │                ┌──────────────────────────────────┐
  │         invalid: "..."   │                │ en: [ SUBTREE, SUBTREE, SUBTREE, │
  │         blank: "..."     │                │       SUBTREE, 0x00000440000E,   │
  │ de:                      │                │       0x00001D0000F, ... ]        │
  │   ...                    │                │ fr: [ SUBTREE, SUBTREE, SUBTREE, │
  └──────────────────────────┘                │       SUBTREE, 0x00004C000012,   │
                                              │       0x000062000011, ... ]       │
  3.3M objects                                │ de: [ ... ]                       │
  513 MB retained                             └──────────────────────────────────┘
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

### 2. `@value_arrays` — Per-Locale Value Arrays

A `Hash` of `{ locale => Array }`. Each Array is indexed by the schema positions and contains only:

- **Positive integers** — packed string table references
- **Negative integers** — object table references (`-(index + 1)`)
- **`SUBTREE_SENTINEL`** (`-(1 << 62)`) — marks subtree nodes
- **`nil`** — key doesn't exist in this locale

```ruby
{
  en: [SUBTREE_SENTINEL, SUBTREE_SENTINEL, ..., 0x00000440000E, ...],
  fr: [SUBTREE_SENTINEL, SUBTREE_SENTINEL, ..., 0x00004C000012, ...],
  # ...
}
```

Ruby integers up to 2^62 are **immediate values** — they consume zero heap memory when stored in an Array. This makes the value arrays essentially free in terms of object overhead; only the Array shell itself is allocated.

### 3. `@string_table` — Binary String Buffer

A single frozen `String` with `Encoding::BINARY` containing all unique translation strings concatenated end-to-end. Strings are deduplicated during building — identical content with the same encoding is stored once.

```
Offset 0          68            150           ...
┌─────────────────┬─────────────┬─────────────┬───
│ is not a valid  │ can't be    │ n'est pas   │
│ email           │ blank       │ un email... │
└─────────────────┴─────────────┴─────────────┴───
```

In the Shopify codebase: **90.6 MB**, holding 1,490,916 unique strings serving 2,774,778 references (1.9x dedup ratio).

### 4. `@objects_table` — Non-String Value Array

A shared frozen `Array` holding all non-string leaf values: Arrays (e.g., day names), Symbols (link targets), Procs, booleans, numbers. Referenced from value arrays by negative index.

In the Shopify codebase: only **308 entries**. Nearly all translations are strings.

### 5. `@subtree_keys` — Subtree Children Index

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
├─ 3. Value array lookup: @value_arrays[:en][6] → 0x00000440000E
│     (one Array index)
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
                    load_path / store_translations
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Nested Hash tree   │
                    │  (@translations)    │◄──────────────────┐
                    └──────────┬──────────┘                   │
                               │                              │
                      eager_load! / compact!         rebuild_nested_tree!
                               │                    (per-locale, on demand)
                               ▼                              │
                    ┌─────────────────────┐                   │
                    │   Compacted mode    │                   │
                    │   (columnar index)  │───────────────────┘
                    └──────────┬──────────┘   store_translations
                               │              (decompacts one locale)
                        reload!│
                               ▼
                    ┌─────────────────────┐
                    │  All state cleared  │
                    │  (back to start)    │
                    └─────────────────────┘
```

### Key behaviors

- **`eager_load!`** calls `super` (loads all YAML files), then `compact!`
- **`compact!`** is idempotent — calling it again when nothing changed is a no-op. If new translations were added since the last compaction, it rebuilds everything from scratch (since packed integer references can't be incrementally merged)
- **`store_translations`** after compaction decompacts only the affected locale by calling `rebuild_nested_tree!`, which reconstitutes the nested Hash from the flat index. The other locales remain compacted
- **`reload!`** clears all compacted state and resets to uninitialized
- **`lookup`** checks `@compacted_locales` to decide whether to use the fast columnar path or fall through to the Simple backend's nested Hash traversal

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
│  @value_arrays:  42 Arrays of integers (47 MB total)          │
│                  (integers are immediate values — 0 bytes each │
│                   on the heap; only the Array backing store)   │
│  @string_table:  1 String (90.6 MB, one contiguous buffer)    │
│  @objects_table: 1 Array (308 entries, 139 KB)                │
│  @subtree_keys:  1 Hash (10.9 MB for parent→children map)    │
│  Total: 163 MB                                                │
└────────────────────────────────────────────────────────────────┘
```

The key insight: Ruby's per-object overhead (~40 bytes for the RValue + type-specific backing storage) dominates when you have millions of small objects. Replacing 3.3 million objects with ~50 large ones eliminates most of this overhead.

## Files

| File | Purpose |
|---|---|
| `lib/i18n/backend/compact.rb` | Implementation (module, ~465 lines) |
| `lib/i18n/backend.rb` | `autoload :Compact` entry |
| `test/backend/compact_test.rb` | Unit tests (25 tests) |
| `test/api/compact_test.rb` | API integration tests (143 tests, all standard I18n::Tests modules) |
| `benchmark/memory.rb` | Synthetic memory benchmark |
| `benchmark/shopify_memory.rb` | Real Shopify files memory benchmark |
| `benchmark/RESULTS.md` | Benchmark results |
