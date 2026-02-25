# Backend::Compact Benchmark Results

Benchmark comparing `I18n::Backend::Simple` vs `I18n::Backend::Simple` + `I18n::Backend::Compact` (binary string table approach).

## Real Shopify i18n Files

**Dataset:** 15,082 YAML files, 261 MB on disk, 42 locales, from `/Users/ufuk/world/trees/root/src/areas/core/shopify/**/config/locales/**/*.yml`

| Metric | Simple | Compact | Change |
|---|---|---|---|
| **RSS delta** | 1,321 MB | 1,081 MB | **18.2% savings** |
| **Retained memory** | 513.3 MB | 163.0 MB | **68.2% savings** |
| **Retained objects** | 3,337,934 | 569,286 | **83% reduction** |
| **Leaf lookup (50k)** | 117.0 ms | 73.3 ms | **1.60x faster** |
| **Load time** | 20.81 s | 26.45 s | ~27% slower (one-time cost) |

### Simple Backend breakdown

| Type | Memory | Objects |
|---|---|---|
| Hash | 333.5 MB | 1,786,626 |
| String | 177.1 MB | 1,491,756 |
| Symbol | 2.2 MB | 59,201 |
| Concurrent::Hash | 404.4 KB | 43 |
| Array | 17.9 KB | 308 |

### Compact Backend breakdown

| Component | Memory | Objects / Detail |
|---|---|---|
| Schema hash | 14.0 MB | 314,159 objects (157,079 keys) |
| Value arrays | 47.3 MB | 37,118 objects (42 arrays of integers) |
| String table | 90.6 MB | 1 binary buffer |
| Objects table | 139.4 KB | 308 entries |
| Subtree index | 10.9 MB | 216,699 objects |
| Marker tree | 9.8 KB | 87 objects |

### String table stats

| Metric | Value |
|---|---|
| String buffer size | 90.6 MB |
| String refs across locales | 2,774,778 |
| Unique packed refs | 1,490,916 |
| Dedup ratio | 1.9x |
| Subtree markers | 1,787,438 |
| Object table entries | 308 |

### Notes

- **RSS vs retained memory:** The RSS savings (18.2%) is lower than retained memory savings (68.2%) because RSS includes transient allocations during YAML parsing that are freed but not returned to the OS. The retained memory figure better represents the steady-state savings in a long-running process after GC compaction.
- **Load time:** The ~27% slower load time is a one-time cost at boot. In production with `eager_load!`, this happens once during startup. With caching enabled (see below), subsequent boots are 12.5x faster.
- **Leaf lookups** are 1.60x faster because the compact path avoids traversing nested Hash chains — it's a single schema hash lookup + array index + buffer slice.
- Only **308 non-string values** exist in the entire Shopify translation corpus (arrays for day/month names, etc.). Nearly all translations are strings.

## Cache Performance (Real Shopify Files)

When a cache file is provided via `eager_load!(cache_path: "...")`, the compacted index is serialized to disk after the first boot. On subsequent boots, the cache is loaded directly — skipping all YAML parsing and compaction.

| Metric | Simple | Compact (fresh) | Compact (cached) |
|---|---|---|---|
| **Load time** | 21.40 s | 26.75 s | **1.71 s** |
| **RSS delta** | 1,348 MB | 1,128 MB | **676 MB** |
| **Retained memory** | 513.3 MB | 163.0 MB | **163.0 MB** |
| **Leaf lookup (50k)** | 108.2 ms | 77.7 ms | **78.8 ms** |

| Comparison | Speedup |
|---|---|
| Cached vs fresh compact! | **15.7x faster** |
| Cached vs Simple | **12.5x faster** |

### Cache details

| Property | Value |
|---|---|
| Cache file size | 147.3 MB |
| Format | Marshal (magic + version + fingerprint + data) |
| Invalidation (default) | File paths + mtimes (SHA256) |
| Invalidation (opt-in) | File content digest (SHA256) |
| Proc handling | Re-evaluates .rb locale files on cache load |

### RSS improvement explained

The cached path has significantly lower RSS (676 MB) than even the fresh compact path (1,128 MB) because it skips YAML parsing entirely. YAML parsing creates millions of transient Ruby objects that, even after GC, leave fragmented heap pages that the OS doesn't reclaim. By never creating those objects in the first place, the cached path avoids this fragmentation.

## Synthetic Benchmark (30 locales × 100 namespaces)

| Metric | Simple | Compact | Change |
|---|---|---|---|
| **Retained memory** | 8.6 MB | 4.6 MB | **46.9% savings** |
| **Leaf lookup (100k)** | 366.6 ms | 271.9 ms | **1.35x faster** |
| **Subtree lookup (50k)** | 159.4 ms | 664.1 ms | **0.24x slower** |

Subtree lookups (e.g., `I18n.t(:errors)` returning a Hash) are slower because the nested structure must be reconstructed on demand. This is an uncommon operation in production.

## How to reproduce

```bash
# Synthetic benchmark
bundle exec ruby benchmark/memory.rb 30 100

# Real Shopify files (includes cache measurement)
bundle exec ruby benchmark/shopify_memory.rb /path/to/shopify
```
