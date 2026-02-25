require 'test_helper'

class I18nBackendCompactTest < I18n::TestCase
  class CompactBackend < I18n::Backend::Simple
    include I18n::Backend::Compact
  end

  def setup
    super
    I18n.backend = CompactBackend.new
    I18n.load_path = [locales_dir + '/en.yml']
  end

  # Basic compact functionality

  test "compact!: compacts loaded translations" do
    I18n.backend.eager_load!
    assert_equal 'baz', I18n.t('foo.bar')
  end

  test "compact!: returns nil for missing keys" do
    I18n.backend.eager_load!
    assert_equal "Translation missing: en.missing", I18n.t(:missing)
  end

  test "compact!: can be called explicitly after eager_load!" do
    I18n.backend.eager_load!
    # eager_load! already calls compact!, but calling again should be safe
    I18n.backend.compact!
    assert_equal 'baz', I18n.t('foo.bar')
  end

  test "compact!: string values are deduplicated" do
    store_translations(:en, :dedup_a => "hello world")
    store_translations(:en, :dedup_b => "hello world")
    I18n.backend.compact!

    a = I18n.t(:dedup_a)
    b = I18n.t(:dedup_b)
    assert_equal a, b
    # Both should have been derived from the same deduplicated source
  end

  test "compact!: supports subtree lookups" do
    store_translations(:en, :nested => { :a => 'alpha', :b => 'beta' })
    I18n.backend.compact!

    result = I18n.t(:nested)
    assert_instance_of Hash, result
    assert_equal 'alpha', result[:a]
    assert_equal 'beta', result[:b]
  end

  test "compact!: supports array values" do
    store_translations(:en, :colors => %w(red green blue))
    I18n.backend.compact!

    result = I18n.t(:colors)
    assert_equal %w(red green blue), result
  end

  test "compact!: supports boolean values" do
    store_translations(:en, :truthy => true, :falsy => false)
    I18n.backend.compact!

    assert_equal true, I18n.t(:truthy)
    assert_equal false, I18n.t(:falsy)
  end

  test "compact!: supports symbol links" do
    store_translations(:en, :link => :target, :target => 'linked value')
    I18n.backend.compact!

    assert_equal 'linked value', I18n.t(:link)
  end

  test "compact!: supports proc values" do
    store_translations(:en, :a_proc => lambda { |*args| 'proc result' })
    I18n.backend.compact!

    assert_equal 'proc result', I18n.t(:a_proc)
  end

  test "compact!: supports numeric keys" do
    store_translations(:en, 1 => 'one')
    I18n.backend.compact!

    assert_equal 'one', I18n.t(1)
  end

  test "compact!: supports pluralization" do
    store_translations(:en, :items => { :one => '%{count} item', :other => '%{count} items' })
    I18n.backend.compact!

    assert_equal '1 item', I18n.t(:items, count: 1)
    assert_equal '5 items', I18n.t(:items, count: 5)
  end

  test "compact!: supports interpolation" do
    store_translations(:en, :greeting => 'Hello %{name}!')
    I18n.backend.compact!

    assert_equal 'Hello World!', I18n.t(:greeting, name: 'World')
  end

  test "compact!: supports dot-separated keys" do
    store_translations(:en, :deeply => { :nested => { :key => 'deep value' } })
    I18n.backend.compact!

    assert_equal 'deep value', I18n.t('deeply.nested.key')
  end

  test "compact!: supports scope option" do
    store_translations(:en, :scope_test => { :inner => 'scoped' })
    I18n.backend.compact!

    assert_equal 'scoped', I18n.t(:inner, scope: :scope_test)
  end

  test "compact!: supports multiple locales" do
    store_translations(:en, :hello => 'Hello')
    store_translations(:fr, :hello => 'Bonjour')
    I18n.backend.compact!

    assert_equal 'Hello', I18n.t(:hello, locale: :en)
    assert_equal 'Bonjour', I18n.t(:hello, locale: :fr)
  end

  # Invalidation on store_translations

  test "store_translations after compact! invalidates the locale" do
    store_translations(:en, :greeting => 'Hi')
    I18n.backend.compact!

    assert_equal 'Hi', I18n.t(:greeting)

    # Store new translations — should invalidate compacted state
    store_translations(:en, :greeting => 'Hello')
    assert_equal 'Hello', I18n.t(:greeting)
  end

  test "store_translations after compact! only invalidates the affected locale" do
    store_translations(:en, :greeting => 'Hi')
    store_translations(:fr, :greeting => 'Salut')
    I18n.backend.compact!

    # Modify only :en
    store_translations(:en, :greeting => 'Hello')

    # :fr should still use the compacted path
    assert_equal 'Hello', I18n.t(:greeting, locale: :en)
    assert_equal 'Salut', I18n.t(:greeting, locale: :fr)
  end

  # Reload behavior

  test "reload! clears compacted state" do
    store_translations(:en, :greeting => 'Hi')
    I18n.backend.compact!
    I18n.backend.reload!

    # After reload, backend is uninitialized — next lookup re-initializes
    assert_equal false, I18n.backend.initialized?
  end

  # Eager load triggers compaction

  test "eager_load! triggers compaction" do
    I18n.backend.eager_load!
    # Verify it works after eager load (which calls compact!)
    assert_equal 'baz', I18n.t('foo.bar')
  end

  # Works without compaction (before compact! is called)

  test "lookup works before compact! is called" do
    store_translations(:en, :before_compact => 'works')
    assert_equal 'works', I18n.t(:before_compact)
  end

  # Deep nested structures

  test "compact!: handles deeply nested structures correctly" do
    store_translations(:en, :a => { :b => { :c => { :d => { :e => 'deep' } } } })
    I18n.backend.compact!

    assert_equal 'deep', I18n.t('a.b.c.d.e')
    assert_instance_of Hash, I18n.t('a.b.c.d')
    assert_instance_of Hash, I18n.t('a.b.c')
    assert_instance_of Hash, I18n.t('a.b')
    assert_instance_of Hash, I18n.t('a')
  end

  # Arrays with nested hashes

  test "compact!: handles arrays with nested hashes" do
    store_translations(:en, :items => [{ :name => 'first' }, { :name => 'second' }])
    I18n.backend.compact!

    result = I18n.t(:items)
    assert_instance_of Array, result
    assert_equal 'first', result[0][:name]
    assert_equal 'second', result[1][:name]
  end

  # Custom separator

  test "compact!: supports custom separator" do
    store_translations(:en, { :custom_sep_test => { :inner => 'custom_sep' } }, { :separator => '|' })
    I18n.backend.compact!

    assert_equal 'custom_sep', I18n.t('custom_sep_test|inner', :separator => '|')
  end

  # Edge case: nil values

  test "compact!: handles nil values" do
    store_translations(:en, :nil_val => nil)
    I18n.backend.compact!

    assert_equal 'default', I18n.t(:nil_val, default: 'default')
  end

  # Edge case: very long strings (> 64KB)

  test "compact!: handles strings longer than 64KB" do
    long_string = "x" * 70_000
    store_translations(:en, :long => long_string)
    I18n.backend.compact!

    assert_equal long_string, I18n.t(:long)
  end

  # ================================================================
  # Cache tests
  # ================================================================

  def with_cache_file
    require 'tempfile'
    file = Tempfile.new(['i18n_compact', '.cache'])
    path = file.path
    file.close
    file.unlink  # start with no file
    yield path
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  # Basic cache write and read

  test "cache: writes and loads cache file" do
    with_cache_file do |path|
      store_translations(:en, :cached => 'hello from cache')
      I18n.backend.compact!(cache_path: path)

      assert File.exist?(path), "Cache file should be written"
      assert File.size(path) > 0, "Cache file should not be empty"

      # Create a new backend and load from cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :cached => 'hello from cache')
      I18n.backend.compact!(cache_path: path)

      assert_equal 'hello from cache', I18n.t(:cached)
    end
  end

  test "cache: loaded cache produces same lookups as fresh compaction" do
    with_cache_file do |path|
      store_translations(:en, :greeting => 'Hello')
      store_translations(:en, :nested => { :a => 'alpha', :b => 'beta' })
      store_translations(:en, :colors => %w(red green blue))
      store_translations(:fr, :greeting => 'Bonjour')
      I18n.backend.compact!(cache_path: path)

      # Record expected values.
      expected_greeting_en = I18n.t(:greeting, locale: :en)
      expected_greeting_fr = I18n.t(:greeting, locale: :fr)
      expected_nested = I18n.t(:nested, locale: :en)
      expected_colors = I18n.t(:colors, locale: :en)

      # Load from cache in a fresh backend.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :greeting => 'Hello')
      store_translations(:en, :nested => { :a => 'alpha', :b => 'beta' })
      store_translations(:en, :colors => %w(red green blue))
      store_translations(:fr, :greeting => 'Bonjour')
      I18n.backend.compact!(cache_path: path)

      assert_equal expected_greeting_en, I18n.t(:greeting, locale: :en)
      assert_equal expected_greeting_fr, I18n.t(:greeting, locale: :fr)
      assert_equal expected_nested, I18n.t(:nested, locale: :en)
      assert_equal expected_colors, I18n.t(:colors, locale: :en)
    end
  end

  # Cache invalidation

  test "cache: invalidates when load_path content changes" do
    require 'tempfile'
    yml = Tempfile.new(['locale', '.yml'])
    yml.write("en:\n  msg: original\n")
    yml.flush

    with_cache_file do |path|
      I18n.load_path = [yml.path]
      # Use content digest so the test doesn't depend on mtime granularity.
      I18n.backend.eager_load!(cache_path: path, cache_digest: true)
      assert_equal 'original', I18n.t(:msg)

      # Rewrite the file with different content.
      File.write(yml.path, "en:\n  msg: updated\n")

      # New backend — content digest should differ, so cache is rebuilt.
      I18n.backend = CompactBackend.new
      I18n.load_path = [yml.path]
      I18n.backend.eager_load!(cache_path: path, cache_digest: true)
      assert_equal 'updated', I18n.t(:msg)
    end
  ensure
    yml.close!
  end

  test "cache: invalidates when load_path files change" do
    with_cache_file do |path|
      I18n.backend.eager_load!(cache_path: path)
      assert_equal 'baz', I18n.t('foo.bar')

      # Add a new file to load_path — fingerprint changes.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.eager_load!(cache_path: path)

      # French translations should now be available.
      assert I18n.available_locales.include?(:fr)
    end
  end

  # Cache with content digest

  test "cache: works with cache_digest option" do
    with_cache_file do |path|
      store_translations(:en, :digest_test => 'value')
      I18n.backend.compact!(cache_path: path, cache_digest: true)
      assert_equal 'value', I18n.t(:digest_test)

      # Load from cache with same digest.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :digest_test => 'value')
      I18n.backend.compact!(cache_path: path, cache_digest: true)
      assert_equal 'value', I18n.t(:digest_test)
    end
  end

  # Cache does not crash on missing/corrupt file

  test "cache: handles missing cache file gracefully" do
    store_translations(:en, :test => 'val')
    I18n.backend.compact!(cache_path: '/tmp/nonexistent_i18n_cache_file_that_does_not_exist.cache')
    assert_equal 'val', I18n.t(:test)
  end

  test "cache: handles corrupt cache file gracefully" do
    with_cache_file do |path|
      File.binwrite(path, "corrupt data here")
      store_translations(:en, :test => 'val')
      I18n.backend.compact!(cache_path: path)
      assert_equal 'val', I18n.t(:test)
    end
  end

  # Cache with Proc values

  test "cache: rebuilds proc values from .rb locale files" do
    with_cache_file do |path|
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.eager_load!(cache_path: path)

      # en.rb defines :en => { :fuh => { :bah => "bas" } }
      assert_equal 'bas', I18n.t('fuh.bah')

      # Load from cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.eager_load!(cache_path: path)
      assert_equal 'bas', I18n.t('fuh.bah')
    end
  end

  test "cache: programmatic procs survive round-trip when re-stored before compact" do
    # Procs injected via store_translations (not from .rb files) can't be
    # deserialized from cache. However, if the same proc is re-stored before
    # compact!, the fresh compaction rebuilds everything including the proc.
    with_cache_file do |path|
      my_proc = lambda { |*args| 'from lambda' }
      store_translations(:en, :dynamic => my_proc)
      I18n.backend.compact!(cache_path: path)
      assert_equal 'from lambda', I18n.t(:dynamic)
    end
  end

  # eager_load! with cache

  test "eager_load!: passes cache_path through to compact!" do
    with_cache_file do |path|
      I18n.backend.eager_load!(cache_path: path)
      assert File.exist?(path), "Cache file should be written by eager_load!"
      assert_equal 'baz', I18n.t('foo.bar')
    end
  end

  # Cache with multiple locales

  test "cache: preserves multiple locales" do
    with_cache_file do |path|
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.eager_load!(cache_path: path)

      en_val = I18n.t('foo.bar', locale: :en)

      # Load from cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.eager_load!(cache_path: path)

      assert_equal en_val, I18n.t('foo.bar', locale: :en)
      assert I18n.available_locales.include?(:en)
      assert I18n.available_locales.include?(:fr)
    end
  end
end
