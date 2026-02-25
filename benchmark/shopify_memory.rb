#!/usr/bin/env ruby
# frozen_string_literal: true

# Memory benchmark for I18n::Backend::Compact using real Shopify i18n files.
#
# Loads all YAML translation files from the Shopify codebase and compares
# the steady-state memory footprint between Simple and Simple + Compact.
#
# Usage:
#   bundle exec ruby benchmark/shopify_memory.rb [locale_dir] [max_files]
#
# Examples:
#   bundle exec ruby benchmark/shopify_memory.rb   # all files
#   bundle exec ruby benchmark/shopify_memory.rb /path/to/shopify 1000  # first 1000 files

$:.unshift File.expand_path('../../lib', __FILE__)

require 'bundler/setup'
require 'i18n'
require 'objspace'

SHOPIFY_DIR = ARGV[0] || "/Users/ufuk/world/trees/root/src/areas/core/shopify"
MAX_FILES = ARGV[1] ? ARGV[1].to_i : nil

# ========== Find all locale YAML files ==========
locale_files = Dir.glob(File.join(SHOPIFY_DIR, "**/config/locales/**/*.yml"))
  .reject { |f| f.include?("/node_modules/") || f.include?("/test/") || f.include?("/lib/development_support/") }
  .sort

if MAX_FILES
  locale_files = locale_files.first(MAX_FILES)
end

total_file_bytes = locale_files.sum { |f| File.size(f) }

puts "=" * 70
puts "I18n Backend Memory Benchmark — Real Shopify Files"
puts "=" * 70
puts
puts "  Source:       #{SHOPIFY_DIR}"
puts "  YAML files:   #{locale_files.size}"
puts "  Total YAML:   #{'%.1f' % (total_file_bytes / 1024.0 / 1024.0)} MB"
puts

# ========== Helpers ==========

def format_number(n)
  n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

def format_bytes(bytes)
  if bytes >= 1024 * 1024
    "#{'%.1f' % (bytes / 1024.0 / 1024.0)} MB"
  elsif bytes >= 1024
    "#{'%.1f' % (bytes / 1024.0)} KB"
  else
    "#{bytes} B"
  end
end

# Get RSS of current process in bytes.
def rss_bytes
  if RUBY_PLATFORM =~ /darwin/
    `ps -o rss= -p #{Process.pid}`.strip.to_i * 1024
  else
    `ps -o rss= -p #{Process.pid}`.strip.to_i * 1024
  end
end

# Walk an object graph measuring retained memory using ObjectSpace.memsize_of.
def measure_retained(root)
  seen = {}.compare_by_identity
  queue = [root]
  total_bytes = 0
  total_objects = 0
  type_bytes = Hash.new(0)
  type_counts = Hash.new(0)

  while (obj = queue.shift)
    next if seen.key?(obj)
    seen[obj] = true
    total_objects += 1

    size = ObjectSpace.memsize_of(obj) rescue 0
    total_bytes += size
    type_bytes[obj.class] += size
    type_counts[obj.class] += 1

    case obj
    when Hash
      obj.each { |k, v| queue << k; queue << v }
    when Array
      obj.each { |v| queue << v }
    end
  end

  { bytes: total_bytes, objects: total_objects, type_bytes: type_bytes, type_counts: type_counts }
end

# Run a block in a forked process and return its result via a pipe.
# This gives us a clean RSS measurement without interference from
# the parent process's memory state.
def measure_in_fork(locale_files, &block)
  reader, writer = IO.pipe

  pid = fork do
    reader.close

    GC.start(full_mark: true, immediate_sweep: true)
    rss_before = rss_bytes

    result = block.call(locale_files)

    GC.start(full_mark: true, immediate_sweep: true)
    GC.start(full_mark: true, immediate_sweep: true)
    sleep 0.1  # let OS update RSS
    rss_after = rss_bytes

    result[:rss_before] = rss_before
    result[:rss_after] = rss_after
    result[:rss_delta] = rss_after - rss_before

    Marshal.dump(result, writer)
    writer.close
    exit!(0)
  end

  writer.close
  data = reader.read
  reader.close
  Process.wait(pid)

  Marshal.load(data)
end

# ========== Count locales ==========
puts "Counting locales..."
locale_counts = Hash.new(0)
sample_keys = []

locale_files.first(100).each do |f|
  begin
    data = YAML.safe_load_file(f, permitted_classes: [Symbol, Date, Time], symbolize_names: true)
    next unless data.is_a?(Hash)
    data.each_key { |k| locale_counts[k] += 1 }
  rescue => e
    # skip problematic files
  end
end

locales_found = locale_counts.keys.sort_by { |k| -locale_counts[k] }
puts "  Locales found (from first 100 files): #{locales_found.first(10).join(', ')}#{locales_found.size > 10 ? '...' : ''} (#{locales_found.size} total)"
puts

# ========== Measure Simple Backend (in fork) ==========
puts "Measuring Simple backend..."
$stdout.flush

simple_result = measure_in_fork(locale_files) do |files|
  backend = I18n::Backend::Simple.new
  I18n.backend = backend

  load_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loaded = 0
  errors = 0
  files.each do |f|
    begin
      I18n.load_path << f
    rescue => e
      errors += 1
    end
  end
  backend.eager_load!
  load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - load_start

  GC.start(full_mark: true, immediate_sweep: true)
  GC.start(full_mark: true, immediate_sweep: true)

  translations = backend.instance_variable_get(:@translations)
  stats = measure_retained(translations)

  # Count leaf strings
  leaf_count = 0
  string_count = 0
  count_leaves = -> (hash) {
    hash.each do |k, v|
      if v.is_a?(Hash)
        count_leaves.call(v)
      else
        leaf_count += 1
        string_count += 1 if v.is_a?(String)
      end
    end
  }
  translations.each { |locale, tree| count_leaves.call(tree) if tree.is_a?(Hash) }

  # Sample lookup keys for benchmarking — find some deep keys
  sample_keys = []
  if translations.size > 0
    first_locale = translations.keys.find { |k| k != :i18n }
    if first_locale && translations[first_locale].is_a?(Hash)
      find_deep_keys = -> (prefix, hash, depth) {
        return if sample_keys.size >= 20
        hash.each do |k, v|
          full = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
          if v.is_a?(Hash)
            find_deep_keys.call(full, v, depth + 1)
          elsif depth >= 2
            sample_keys << [first_locale, full]
          end
        end
      }
      find_deep_keys.call("", translations[first_locale], 0)
    end
  end

  # Lookup benchmark
  if sample_keys.size > 0
    # Warm up
    sample_keys.each { |locale, key| backend.translate(locale, key) rescue nil }

    lookup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50_000.times do
      locale, key = sample_keys[0]
      backend.translate(locale, key) rescue nil
    end
    lookup_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - lookup_start
  else
    lookup_time = 0
  end

  {
    retained_bytes: stats[:bytes],
    retained_objects: stats[:objects],
    type_bytes: stats[:type_bytes],
    type_counts: stats[:type_counts],
    load_time: load_time,
    lookup_time: lookup_time,
    num_locales: translations.size,
    leaf_count: leaf_count,
    string_count: string_count,
    errors: errors,
    sample_keys: sample_keys,
  }
end

# ========== Measure Compact Backend (in fork) ==========
puts "Measuring Compact backend..."
$stdout.flush

compact_result = measure_in_fork(locale_files) do |files|
  compact_backend_class = Class.new(I18n::Backend::Simple) do
    include I18n::Backend::Compact
  end
  backend = compact_backend_class.new
  I18n.backend = backend

  load_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  errors = 0
  files.each do |f|
    begin
      I18n.load_path << f
    rescue => e
      errors += 1
    end
  end
  backend.eager_load!  # this calls compact! automatically
  load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - load_start

  GC.start(full_mark: true, immediate_sweep: true)
  GC.start(full_mark: true, immediate_sweep: true)

  # Measure each component
  schema = backend.instance_variable_get(:@schema)
  value_arrays = backend.instance_variable_get(:@value_arrays)
  translations = backend.instance_variable_get(:@translations)
  subtree_keys = backend.instance_variable_get(:@subtree_keys)
  string_table = backend.instance_variable_get(:@string_table)
  objects_table = backend.instance_variable_get(:@objects_table)

  schema_stats = measure_retained(schema)
  values_stats = measure_retained(value_arrays)
  tree_stats = measure_retained(translations)
  subtree_stats = subtree_keys ? measure_retained(subtree_keys) : { bytes: 0, objects: 0 }
  string_table_bytes = string_table ? (ObjectSpace.memsize_of(string_table) rescue 0) : 0
  objects_table_stats = objects_table ? measure_retained(objects_table) : { bytes: 0, objects: 0 }

  total_bytes = schema_stats[:bytes] + values_stats[:bytes] + tree_stats[:bytes] +
                subtree_stats[:bytes] + string_table_bytes + objects_table_stats[:bytes]
  total_objects = schema_stats[:objects] + values_stats[:objects] + tree_stats[:objects] +
                  subtree_stats[:objects] + 1 + objects_table_stats[:objects]

  # Count string refs and object refs
  total_string_refs = 0
  total_object_refs = 0
  total_subtree_markers = 0
  unique_packed = {}
  value_arrays.each do |_, arr|
    arr.each do |v|
      next if v.nil?
      if v.is_a?(Integer)
        if v == -(1 << 62)
          total_subtree_markers += 1
        elsif v >= 0
          total_string_refs += 1
          unique_packed[v] = true
        else
          total_object_refs += 1
        end
      end
    end
  end

  # Use sample keys from simple measurement (passed via the sample_keys variable)
  # We'll reconstruct sample keys from the schema
  sample_keys = []
  if schema.size > 0
    first_locale = value_arrays.keys.first
    schema.each do |sym_key, idx|
      break if sample_keys.size >= 20
      str_key = sym_key.to_s
      next unless str_key.include?(".")  # only deep keys
      packed = value_arrays[first_locale]&.[](idx)
      next if packed.nil? || packed == -(1 << 62)  # skip nil and subtree markers
      sample_keys << [first_locale, str_key]
    end
  end

  # Lookup benchmark
  if sample_keys.size > 0
    # Warm up
    sample_keys.each { |locale, key| backend.translate(locale, key) rescue nil }

    lookup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50_000.times do
      locale, key = sample_keys[0]
      backend.translate(locale, key) rescue nil
    end
    lookup_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - lookup_start
  else
    lookup_time = 0
  end

  {
    retained_bytes: total_bytes,
    retained_objects: total_objects,
    schema_bytes: schema_stats[:bytes],
    schema_objects: schema_stats[:objects],
    values_bytes: values_stats[:bytes],
    values_objects: values_stats[:objects],
    string_table_bytes: string_table_bytes,
    string_table_data_bytes: string_table ? string_table.bytesize : 0,
    objects_table_bytes: objects_table_stats[:bytes],
    objects_table_objects: objects_table_stats[:objects],
    objects_table_entries: objects_table ? objects_table.size : 0,
    subtree_bytes: subtree_stats[:bytes],
    subtree_objects: subtree_stats[:objects],
    tree_bytes: tree_stats[:bytes],
    tree_objects: tree_stats[:objects],
    load_time: load_time,
    lookup_time: lookup_time,
    num_locales: value_arrays.size,
    schema_keys: schema.size,
    total_string_refs: total_string_refs,
    total_object_refs: total_object_refs,
    total_subtree_markers: total_subtree_markers,
    unique_packed_refs: unique_packed.size,
    errors: errors,
    sample_keys: sample_keys,
  }
end

# ========== Results ==========
puts
puts "-" * 70
puts "Simple Backend (baseline)"
puts "-" * 70
puts "  RSS delta:        #{format_bytes(simple_result[:rss_delta])}"
puts "  Retained memory:  #{format_bytes(simple_result[:retained_bytes])}"
puts "  Retained objects: #{format_number(simple_result[:retained_objects])}"
puts "  Locales:          #{simple_result[:num_locales]}"
puts "  Leaf values:      #{format_number(simple_result[:leaf_count])}"
puts "  String values:    #{format_number(simple_result[:string_count])}"
puts "  Load time:        #{'%.2f' % simple_result[:load_time]} s"
puts "  Lookup (50k):     #{'%.1f' % (simple_result[:lookup_time] * 1000)} ms"
puts "  Load errors:      #{simple_result[:errors]}"
puts "  Breakdown by type:"
simple_result[:type_bytes].sort_by { |_, v| -v }.first(8).each do |klass, bytes|
  puts "    #{klass}: #{format_bytes(bytes)} (#{format_number(simple_result[:type_counts][klass])} objects)"
end

puts
puts "-" * 70
puts "Simple + Compact Backend"
puts "-" * 70
puts "  RSS delta:        #{format_bytes(compact_result[:rss_delta])}"
puts "  Retained memory:  #{format_bytes(compact_result[:retained_bytes])}"
puts "  Retained objects: #{format_number(compact_result[:retained_objects])}"
puts "  Locales:          #{compact_result[:num_locales]}"
puts "  Schema keys:      #{format_number(compact_result[:schema_keys])}"
puts "  Load time:        #{'%.2f' % compact_result[:load_time]} s (includes compact!)"
puts "  Lookup (50k):     #{'%.1f' % (compact_result[:lookup_time] * 1000)} ms"
puts "  Load errors:      #{compact_result[:errors]}"
puts "  Breakdown:"
puts "    Schema hash:     #{format_bytes(compact_result[:schema_bytes])} (#{format_number(compact_result[:schema_objects])} objects)"
puts "    Value arrays:    #{format_bytes(compact_result[:values_bytes])} (#{format_number(compact_result[:values_objects])} objects)"
puts "    String table:    #{format_bytes(compact_result[:string_table_bytes])} (1 buffer, #{format_bytes(compact_result[:string_table_data_bytes])} data)"
puts "    Objects table:   #{format_bytes(compact_result[:objects_table_bytes])} (#{format_number(compact_result[:objects_table_entries])} entries)"
puts "    Subtree index:   #{format_bytes(compact_result[:subtree_bytes])} (#{format_number(compact_result[:subtree_objects])} objects)"
puts "    Marker tree:     #{format_bytes(compact_result[:tree_bytes])} (#{format_number(compact_result[:tree_objects])} objects)"
puts "  String table stats:"
puts "    String refs across locales: #{format_number(compact_result[:total_string_refs])}"
puts "    Unique packed refs:         #{format_number(compact_result[:unique_packed_refs])}"
puts "    Dedup ratio:                #{'%.1f' % (compact_result[:total_string_refs].to_f / [compact_result[:unique_packed_refs], 1].max)}x"
puts "    Object table entries:       #{format_number(compact_result[:objects_table_entries])}"
puts "    Subtree markers:            #{format_number(compact_result[:total_subtree_markers])}"

puts
puts "=" * 70
puts "Comparison"
puts "=" * 70

rss_savings = (1 - compact_result[:rss_delta].to_f / [simple_result[:rss_delta], 1].max) * 100
mem_savings = (1 - compact_result[:retained_bytes].to_f / [simple_result[:retained_bytes], 1].max) * 100
leaf_speedup = simple_result[:lookup_time] > 0 && compact_result[:lookup_time] > 0 ?
  simple_result[:lookup_time] / compact_result[:lookup_time] : 0

puts
puts "  RSS delta:       #{format_bytes(simple_result[:rss_delta])} -> #{format_bytes(compact_result[:rss_delta])} (#{'%.1f' % rss_savings}% #{rss_savings > 0 ? 'savings' : 'increase'})"
puts "  Retained memory: #{format_bytes(simple_result[:retained_bytes])} -> #{format_bytes(compact_result[:retained_bytes])} (#{'%.1f' % mem_savings}% #{mem_savings > 0 ? 'savings' : 'increase'})"
puts "  Load time:       #{'%.2f' % simple_result[:load_time]} s -> #{'%.2f' % compact_result[:load_time]} s"
if leaf_speedup > 0
  puts "  Leaf lookup:     #{'%.1f' % (simple_result[:lookup_time] * 1000)} ms -> #{'%.1f' % (compact_result[:lookup_time] * 1000)} ms (#{'%.2f' % leaf_speedup}x #{leaf_speedup > 1 ? 'faster' : 'slower'})"
end
puts
puts "  Sample lookup keys used:"
keys = compact_result[:sample_keys] || simple_result[:sample_keys] || []
keys.first(5).each { |locale, key| puts "    #{locale}: #{key}" }
puts "    ..." if keys.size > 5
puts

# ========== Measure Compact Backend with Cache (in fork) ==========
# First, build the cache file in a separate fork.
cache_path = "/tmp/i18n_compact_benchmark_#{Process.pid}.cache"

puts "Building cache file..."
$stdout.flush

build_cache_result = measure_in_fork(locale_files) do |files|
  compact_backend_class = Class.new(I18n::Backend::Simple) do
    include I18n::Backend::Compact
  end
  backend = compact_backend_class.new
  I18n.backend = backend

  files.each { |f| I18n.load_path << f }
  backend.eager_load!(cache_path: cache_path)

  cache_size = File.exist?(cache_path) ? File.size(cache_path) : 0
  { cache_size: cache_size }
end

puts "  Cache file: #{format_bytes(build_cache_result[:cache_size])}"
puts

# Now measure loading from cache in a fresh fork.
puts "Measuring Compact backend (from cache)..."
$stdout.flush

cached_result = measure_in_fork(locale_files) do |files|
  compact_backend_class = Class.new(I18n::Backend::Simple) do
    include I18n::Backend::Compact
  end
  backend = compact_backend_class.new
  I18n.backend = backend

  load_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  files.each { |f| I18n.load_path << f }
  backend.eager_load!(cache_path: cache_path)
  load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - load_start

  GC.start(full_mark: true, immediate_sweep: true)
  GC.start(full_mark: true, immediate_sweep: true)

  # Measure components (same as compact measurement)
  schema = backend.instance_variable_get(:@schema)
  value_arrays = backend.instance_variable_get(:@value_arrays)
  translations = backend.instance_variable_get(:@translations)
  subtree_keys = backend.instance_variable_get(:@subtree_keys)
  string_table = backend.instance_variable_get(:@string_table)
  objects_table = backend.instance_variable_get(:@objects_table)

  schema_stats = measure_retained(schema)
  values_stats = measure_retained(value_arrays)
  tree_stats = measure_retained(translations)
  subtree_stats = subtree_keys ? measure_retained(subtree_keys) : { bytes: 0, objects: 0 }
  string_table_bytes = string_table ? (ObjectSpace.memsize_of(string_table) rescue 0) : 0
  objects_table_stats = objects_table ? measure_retained(objects_table) : { bytes: 0, objects: 0 }

  total_bytes = schema_stats[:bytes] + values_stats[:bytes] + tree_stats[:bytes] +
                subtree_stats[:bytes] + string_table_bytes + objects_table_stats[:bytes]

  # Lookup benchmark
  sample_keys = []
  if schema.size > 0
    first_locale = value_arrays.keys.first
    schema.each do |sym_key, idx|
      break if sample_keys.size >= 20
      str_key = sym_key.to_s
      next unless str_key.include?(".")
      packed = value_arrays[first_locale]&.[](idx)
      next if packed.nil? || packed == -(1 << 62)
      sample_keys << [first_locale, str_key]
    end
  end

  lookup_time = 0
  if sample_keys.size > 0
    sample_keys.each { |locale, key| backend.translate(locale, key) rescue nil }
    lookup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50_000.times do
      locale, key = sample_keys[0]
      backend.translate(locale, key) rescue nil
    end
    lookup_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - lookup_start
  end

  {
    retained_bytes: total_bytes,
    load_time: load_time,
    lookup_time: lookup_time,
    num_locales: value_arrays.size,
  }
end

# Clean up cache file.
File.delete(cache_path) if File.exist?(cache_path)

puts
puts "-" * 70
puts "Simple + Compact Backend (from cache)"
puts "-" * 70
puts "  RSS delta:        #{format_bytes(cached_result[:rss_delta])}"
puts "  Retained memory:  #{format_bytes(cached_result[:retained_bytes])}"
puts "  Locales:          #{cached_result[:num_locales]}"
puts "  Load time:        #{'%.2f' % cached_result[:load_time]} s (from cache)"
puts "  Lookup (50k):     #{'%.1f' % (cached_result[:lookup_time] * 1000)} ms"
puts "  Cache file:       #{format_bytes(build_cache_result[:cache_size])}"

cache_speedup = compact_result[:load_time] > 0 && cached_result[:load_time] > 0 ?
  compact_result[:load_time] / cached_result[:load_time] : 0
total_speedup = simple_result[:load_time] > 0 && cached_result[:load_time] > 0 ?
  simple_result[:load_time] / cached_result[:load_time] : 0

puts
puts "=" * 70
puts "Cache Comparison"
puts "=" * 70
puts
puts "  Load time:  Simple #{'%.2f' % simple_result[:load_time]} s -> Compact #{'%.2f' % compact_result[:load_time]} s -> Cached #{'%.2f' % cached_result[:load_time]} s"
if cache_speedup > 0
  puts "  Speedup vs fresh compact!: #{'%.1f' % cache_speedup}x faster"
end
if total_speedup > 0
  puts "  Speedup vs Simple:         #{'%.1f' % total_speedup}x faster"
end
puts
