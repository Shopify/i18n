#!/usr/bin/env ruby
# frozen_string_literal: true

# Memory benchmark for I18n::Backend::Compact
#
# Compares the steady-state memory footprint and lookup performance
# between the Simple backend and Simple + Compact.
#
# Usage:
#   bundle exec ruby benchmark/memory.rb
#   bundle exec ruby benchmark/memory.rb [num_locales] [num_namespaces]

$:.unshift File.expand_path('../../lib', __FILE__)

require 'bundler/setup'
require 'i18n'
require 'objspace'

NUM_LOCALES = (ARGV[0] || 10).to_i
NUM_TOP_KEYS = (ARGV[1] || 50).to_i

# Generate a realistic translation tree.
def generate_translations(num_top_keys, locale_index)
  data = {}

  num_top_keys.times do |i|
    namespace = :"namespace_#{i}"
    data[namespace] = {}

    5.times do |j|
      scope = :"scope_#{j}"
      data[namespace][scope] = {}

      8.times do |k|
        key = :"key_#{k}"
        data[namespace][scope][key] = case k % 4
        when 0 then "Translation for #{namespace}.#{scope}.#{key} in locale #{locale_index}"
        when 1 then "This is a shared message with %{count} items"
        when 2 then "Another shared message: %{name} did something"
        when 3 then "Locale-specific: #{locale_index}-#{i}-#{j}-#{k}"
        end
      end

      data[namespace][scope][:count_msg] = {
        one: "%{count} item in #{namespace}.#{scope}",
        other: "%{count} items in #{namespace}.#{scope}",
      }
    end
  end

  data[:date] = {
    formats: { default: "%Y-%m-%d", short: "%b %d", long: "%B %d, %Y" },
    day_names: %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday],
    abbr_day_names: %w[Sun Mon Tue Wed Thu Fri Sat],
    month_names: [nil, "January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November", "December"],
  }

  data
end

# Measure retained memory of an object graph using ObjectSpace.memsize_of.
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

# Pre-generate translation data.
locales = NUM_LOCALES.times.map { |i| :"locale_#{i}" }
translations_data = {}
locales.each_with_index do |locale, i|
  translations_data[locale] = generate_translations(NUM_TOP_KEYS, i)
end

leaf_count = NUM_LOCALES * (NUM_TOP_KEYS * 5 * (8 + 2) + 4 + 7 + 7 + 13)

puts "=" * 70
puts "I18n Backend Memory Benchmark"
puts "=" * 70
puts
puts "  Locales:      #{NUM_LOCALES}"
puts "  Namespaces:   #{NUM_TOP_KEYS}"
puts "  Scopes/ns:    5"
puts "  Keys/scope:   ~10"
puts "  Total leaves: ~#{format_number(leaf_count)}"
puts

# ========== Simple Backend ==========
simple_backend = I18n::Backend::Simple.new
translations_data.each { |locale, data| simple_backend.store_translations(locale, data) }
GC.start(full_mark: true, immediate_sweep: true)
GC.start(full_mark: true, immediate_sweep: true)

simple_stats = measure_retained(simple_backend.instance_variable_get(:@translations))

I18n.backend = simple_backend
# Warm up normalized key cache
simple_backend.translate(:locale_0, :"namespace_25.scope_3.key_5")
simple_backend.translate(:locale_0, :"namespace_25.scope_3")

simple_leaf_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100_000.times { simple_backend.translate(:locale_0, :"namespace_25.scope_3.key_5") }
simple_leaf_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - simple_leaf_start

simple_subtree_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
50_000.times { simple_backend.translate(:locale_0, :"namespace_25.scope_3") }
simple_subtree_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - simple_subtree_start

# ========== Compact Backend ==========
compact_backend_class = Class.new(I18n::Backend::Simple) do
  include I18n::Backend::Compact
end
compact_backend = compact_backend_class.new
translations_data.each { |locale, data| compact_backend.store_translations(locale, data) }
compact_backend.compact!
GC.start(full_mark: true, immediate_sweep: true)
GC.start(full_mark: true, immediate_sweep: true)

compact_schema_stats = measure_retained(compact_backend.instance_variable_get(:@schema))
compact_values_stats = measure_retained(compact_backend.instance_variable_get(:@value_arrays))
compact_tree_stats = measure_retained(compact_backend.instance_variable_get(:@translations))
compact_subtree_stats = measure_retained(compact_backend.instance_variable_get(:@subtree_keys))

compact_total_bytes = compact_schema_stats[:bytes] + compact_values_stats[:bytes] + compact_tree_stats[:bytes] + compact_subtree_stats[:bytes]
compact_total_objects = compact_schema_stats[:objects] + compact_values_stats[:objects] + compact_tree_stats[:objects] + compact_subtree_stats[:objects]

I18n.backend = compact_backend
# Warm up
compact_backend.translate(:locale_0, :"namespace_25.scope_3.key_5")
compact_backend.translate(:locale_0, :"namespace_25.scope_3")

compact_leaf_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100_000.times { compact_backend.translate(:locale_0, :"namespace_25.scope_3.key_5") }
compact_leaf_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - compact_leaf_start

compact_subtree_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
50_000.times { compact_backend.translate(:locale_0, :"namespace_25.scope_3") }
compact_subtree_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - compact_subtree_start

# ========== Results ==========
puts "-" * 70
puts "Simple Backend (baseline)"
puts "-" * 70
puts "  Retained memory:  #{format_bytes(simple_stats[:bytes])}"
puts "  Retained objects: #{format_number(simple_stats[:objects])}"
puts "  Breakdown:"
simple_stats[:type_bytes].sort_by { |_, v| -v }.first(5).each do |klass, bytes|
  puts "    #{klass}: #{format_bytes(bytes)} (#{format_number(simple_stats[:type_counts][klass])} objects)"
end
puts "  Leaf lookup (100k):    #{'%.1f' % (simple_leaf_time * 1000)} ms"
puts "  Subtree lookup (50k):  #{'%.1f' % (simple_subtree_time * 1000)} ms"
puts

puts "-" * 70
puts "Simple + Compact Backend"
puts "-" * 70
puts "  Retained memory:  #{format_bytes(compact_total_bytes)}"
puts "  Retained objects: #{format_number(compact_total_objects)}"
puts "  Breakdown:"
puts "    Schema hash:     #{format_bytes(compact_schema_stats[:bytes])} (#{format_number(compact_schema_stats[:objects])} objects)"
puts "    Value arrays:    #{format_bytes(compact_values_stats[:bytes])} (#{format_number(compact_values_stats[:objects])} objects)"
puts "    Subtree index:   #{format_bytes(compact_subtree_stats[:bytes])} (#{format_number(compact_subtree_stats[:objects])} objects)"
puts "    Marker tree:     #{format_bytes(compact_tree_stats[:bytes])} (#{format_number(compact_tree_stats[:objects])} objects)"
puts "  Leaf lookup (100k):    #{'%.1f' % (compact_leaf_time * 1000)} ms"
puts "  Subtree lookup (50k):  #{'%.1f' % (compact_subtree_time * 1000)} ms"
puts

puts "=" * 70
puts "Comparison"
puts "=" * 70

mem_savings = (1 - compact_total_bytes.to_f / simple_stats[:bytes]) * 100
obj_savings = (1 - compact_total_objects.to_f / simple_stats[:objects]) * 100
leaf_speedup = simple_leaf_time / compact_leaf_time
subtree_speedup = simple_subtree_time / compact_subtree_time

puts
puts "  Memory:          #{format_bytes(simple_stats[:bytes])} -> #{format_bytes(compact_total_bytes)} (#{'%.1f' % mem_savings}% #{mem_savings > 0 ? 'savings' : 'increase'})"
puts "  Objects:         #{format_number(simple_stats[:objects])} -> #{format_number(compact_total_objects)} (#{'%.1f' % obj_savings}% #{obj_savings > 0 ? 'reduction' : 'increase'})"
puts "  Leaf lookup:     #{'%.1f' % (simple_leaf_time * 1000)} ms -> #{'%.1f' % (compact_leaf_time * 1000)} ms (#{'%.2f' % leaf_speedup}x #{leaf_speedup > 1 ? 'faster' : 'slower'})"
puts "  Subtree lookup:  #{'%.1f' % (simple_subtree_time * 1000)} ms -> #{'%.1f' % (compact_subtree_time * 1000)} ms (#{'%.2f' % subtree_speedup}x #{subtree_speedup > 1 ? 'faster' : 'slower'})"
puts

# ========== String Deduplication ==========
puts "-" * 70
puts "String Deduplication"
puts "-" * 70
value_arrays = compact_backend.instance_variable_get(:@value_arrays)
all_values = []
value_arrays.each { |_, arr| arr.each { |v| all_values << v if v.is_a?(String) } }
total = all_values.size
unique_id = all_values.group_by(&:object_id).size
unique_content = all_values.uniq.size
puts "  Strings across all locales: #{format_number(total)}"
puts "  Unique by content:          #{format_number(unique_content)}"
puts "  Unique by object identity:  #{format_number(unique_id)}"
puts "  Strings shared via dedup:   #{format_number(total - unique_id)} (#{((total - unique_id).to_f / [total, 1].max * 100).round(1)}%)"
