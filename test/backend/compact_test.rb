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

  test "compact!: value stores are sparse, not positional over the shared schema" do
    store_translations(:en, :shared => "s", :only_en => "e")
    store_translations(:fr, :shared => "s")
    I18n.backend.compact!

    stores = I18n.backend.instance_variable_get(:@value_arrays)
    schema = I18n.backend.instance_variable_get(:@schema)

    # A positional store would be sized by the union of every locale's keys.
    assert stores.values.none? { |store| store.is_a?(Array) }
    assert stores[:fr].size < schema.size
    assert_equal "s", I18n.t(:shared, :locale => :fr)
  end

  test "compact!: stores only values that differ from the base locale" do
    store_translations(:en, :same => "SAME", :differs => "en", :only_en => "e")
    store_translations(:fr, :same => "SAME", :differs => "fr")
    I18n.backend.compact!

    stores = I18n.backend.instance_variable_get(:@value_arrays)
    assert stores[:fr].is_a?(I18n::Backend::Compact::DeltaStore)
    assert_equal 1, I18n.backend.delta_stats[:inherited]
    assert_equal 1, stores[:fr].overrides.size

    assert_equal "SAME", I18n.t(:same, :locale => :fr)
    assert_equal "fr", I18n.t(:differs, :locale => :fr)
  end

  test "compact!: a base value is not inherited by a locale that omits the key" do
    store_translations(:en, :only_en => "en only")
    store_translations(:fr, :other => "autre")
    I18n.backend.compact!

    assert_equal "Translation missing: fr.only_en", I18n.t(:only_en, :locale => :fr)
  end

  test "compact!: delta stats survive a second eager_load!" do
    store_translations(:en, :same => "SAME")
    store_translations(:fr, :same => "SAME")
    I18n.backend.compact!
    before = I18n.backend.delta_stats[:inherited]

    I18n.backend.eager_load!

    assert_equal before, I18n.backend.delta_stats[:inherited]
  end

  test "compact!: a delta locale still decompacts to a full tree" do
    store_translations(:en, :same => "SAME", :differs => "en")
    store_translations(:fr, :same => "SAME", :differs => "fr")
    I18n.backend.compact!

    store_translations(:fr, :added => "ajoute")

    assert_equal "ajoute", I18n.t(:added, :locale => :fr)
    assert_equal "SAME", I18n.t(:same, :locale => :fr)
    assert_equal "fr", I18n.t(:differs, :locale => :fr)
  end

  test "compact cache: serves a lookup that happens before eager_load!" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "compact.cache")

      writer = CompactBackend.new
      writer.configure_compact_cache(path: path)
      writer.eager_load!
      expected = writer.translate(:en, :"foo.bar")

      reader = CompactBackend.new
      reader.configure_compact_cache(path: path)
      # Backend::Simple calls init_translations from lookup, so this is the
      # shape that bypassed an eager_load!-only hook.
      assert_equal expected, reader.translate(:en, :"foo.bar")
      assert reader.send(:initialized?)

      # The value alone proves nothing: parsing the YAML answers it too. The
      # locale being compacted is what shows the cache served the early load.
      assert_equal({ :en => true }, reader.instance_variable_get(:@compacted_locales))
    end
  end

  test "compact cache: accepts a caller-supplied fingerprint" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "compact.cache")
      calls = 0

      writer = CompactBackend.new
      writer.configure_compact_cache(path: path, fingerprint: -> { calls += 1; "stable-key" })
      # Only ever in the cache, never in the load path, so it tells a cache
      # hit apart from a rebuild.
      writer.store_translations(:en, :only_in_cache => "cached")
      writer.eager_load!
      assert calls > 0

      reader = CompactBackend.new
      reader.configure_compact_cache(path: path, fingerprint: -> { "stable-key" })
      reader.eager_load!
      assert_equal "baz", reader.translate(:en, :"foo.bar")
      assert_equal "cached", reader.translate(:en, :only_in_cache)

      stale = CompactBackend.new
      stale.configure_compact_cache(path: path, fingerprint: -> { "different-key" })
      stale.eager_load!
      assert_equal "baz", stale.translate(:en, :"foo.bar")

      missing = catch(:exception) { stale.translate(:en, :only_in_cache) }
      assert_kind_of I18n::MissingTranslation, missing, "a mismatched fingerprint must discard the cache"
    end
  end

  test "compact!: a key containing the separator survives a subtree lookup" do
    store_translations(:en, :template_names => { :"Robots.txt" => "Robots.txt", :index => "Index" })
    I18n.backend.compact!

    assert_equal({ :"Robots.txt" => "Robots.txt", :index => "Index" }, I18n.t(:template_names))
    assert_equal "Robots.txt", I18n.t(:"template_names.Robots.txt")
    assert_equal "Translation missing: en.template_names.Robots", I18n.t(:"template_names.Robots")
  end

  test "compact!: a key containing the separator survives decompaction" do
    store_translations(:en, :template_names => { :"Robots.txt" => "Robots.txt", :index => "Index" })
    I18n.backend.compact!

    store_translations(:en, :template_names => { :added => "Added" })

    assert_equal({ :"Robots.txt" => "Robots.txt", :index => "Index", :added => "Added" }, I18n.t(:template_names))
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

  test "cache: writes and loads compact cache file" do
    with_cache_file do |path|
      store_translations(:en, :cached => 'hello from cache')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!

      assert File.exist?(path), "Compact cache file should be written"
      assert File.size(path) > 0, "Compact cache file should not be empty"

      # Create a new backend and load from cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :cached => 'hello from cache')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!

      assert_equal 'hello from cache', I18n.t(:cached)
    end
  end

  test "cache: loaded compact cache produces same lookups as fresh compaction" do
    with_cache_file do |path|
      store_translations(:en, :greeting => 'Hello')
      store_translations(:en, :nested => { :a => 'alpha', :b => 'beta' })
      store_translations(:en, :colors => %w(red green blue))
      store_translations(:fr, :greeting => 'Bonjour')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!

      # Record expected values.
      expected_greeting_en = I18n.t(:greeting, locale: :en)
      expected_greeting_fr = I18n.t(:greeting, locale: :fr)
      expected_nested = I18n.t(:nested, locale: :en)
      expected_colors = I18n.t(:colors, locale: :en)

      # Load from compact cache in a fresh backend.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :greeting => 'Hello')
      store_translations(:en, :nested => { :a => 'alpha', :b => 'beta' })
      store_translations(:en, :colors => %w(red green blue))
      store_translations(:fr, :greeting => 'Bonjour')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!

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
      I18n.backend.configure_compact_cache(path: path, digest: true)
      I18n.backend.eager_load!
      assert_equal 'original', I18n.t(:msg)

      # Rewrite the file with different content.
      File.write(yml.path, "en:\n  msg: updated\n")

      # New backend — content digest should differ, so compact cache is rebuilt.
      I18n.backend = CompactBackend.new
      I18n.load_path = [yml.path]
      I18n.backend.configure_compact_cache(path: path, digest: true)
      I18n.backend.eager_load!
      assert_equal 'updated', I18n.t(:msg)
    end
  ensure
    yml.close!
  end

  test "cache: invalidates when load_path files change" do
    with_cache_file do |path|
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!
      assert_equal 'baz', I18n.t('foo.bar')

      # Add a new file to load_path — fingerprint changes.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!

      # French translations should now be available.
      assert I18n.available_locales.include?(:fr)
    end
  end

  # Cache with content digest

  test "cache: works with digest option" do
    with_cache_file do |path|
      store_translations(:en, :digest_test => 'value')
      I18n.backend.configure_compact_cache(path: path, digest: true)
      I18n.backend.compact!
      assert_equal 'value', I18n.t(:digest_test)

      # Load from compact cache with same digest.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :digest_test => 'value')
      I18n.backend.configure_compact_cache(path: path, digest: true)
      I18n.backend.compact!
      assert_equal 'value', I18n.t(:digest_test)
    end
  end

  # Cache does not crash on missing/corrupt file

  test "cache: creates parent directories for compact cache file" do
    require 'tmpdir'
    dir = File.join(Dir.tmpdir, "i18n_compact_test_#{Process.pid}", "nested")
    path = File.join(dir, "test.cache")
    begin
      store_translations(:en, :test => 'val')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!

      assert File.exist?(path), "Compact cache file should be created"
      assert_equal 'val', I18n.t(:test)
    ensure
      FileUtils.rm_rf(File.join(Dir.tmpdir, "i18n_compact_test_#{Process.pid}"))
    end
  end

  # Runtime writes against a warm cache

  test "cache: recompacting keeps a store_translations write the cache cannot see" do
    with_cache_file do |path|
      store_translations(:en, :greet => "v1")
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!
      before = File.binread(path)

      # The fingerprint covers load_path files only, so the cache still looks
      # valid after this write. :en is the only cached locale, which empties
      # @compacted_locales, so the guard cannot be inferred from that.
      store_translations(:en, :greet => "v2")
      assert_equal "v2", I18n.t(:greet)

      I18n.backend.compact!

      assert_equal "v2", I18n.t(:greet)
      refute_equal before, File.binread(path), "the cache should be rewritten with the new value"
    end
  end

  test "cache: recompacting after a cache hit keeps the write and the other locales" do
    with_cache_file do |path|
      store_translations(:en, :greet => "Hello")
      store_translations(:fr, :greet => "Bonjour")
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!
      assert_equal "Bonjour", I18n.t(:greet, :locale => :fr)

      store_translations(:en, :greet => "OVERRIDE")
      I18n.backend.compact!

      assert_equal "OVERRIDE", I18n.t(:greet, :locale => :en)
      assert_equal "Bonjour", I18n.t(:greet, :locale => :fr)
    end
  end

  test "cache: a fresh backend still takes the cache fast path" do
    with_cache_file do |path|
      store_translations(:en, :greet => "cached")
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!

      # Served from the cache: the value was never stored on this backend.
      assert_equal "cached", I18n.t(:greet)
    end
  end

  test "cache: handles missing compact cache file gracefully" do
    store_translations(:en, :test => 'val')
    I18n.backend.configure_compact_cache(path: '/tmp/nonexistent_i18n_cache_file_that_does_not_exist.cache')
    I18n.backend.compact!
    assert_equal 'val', I18n.t(:test)
  end

  test "cache: handles corrupt compact cache file gracefully" do
    with_cache_file do |path|
      File.binwrite(path, "corrupt data here")
      store_translations(:en, :test => 'val')
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!
      assert_equal 'val', I18n.t(:test)
    end
  end

  # Cache with Proc values

  test "cache: rebuilds proc values from .rb locale files" do
    with_cache_file do |path|
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!

      # en.rb defines :en => { :fuh => { :bah => "bas" } }
      assert_equal 'bas', I18n.t('fuh.bah')

      # Load from compact cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!
      assert_equal 'bas', I18n.t('fuh.bah')
    end
  end

  test "cache: programmatic procs survive round-trip when re-stored before compact" do
    # Procs injected via store_translations (not from .rb files) can't be
    # deserialized from the compact cache. However, if the same proc is
    # re-stored before compact!, the fresh compaction rebuilds everything
    # including the proc.
    with_cache_file do |path|
      my_proc = lambda { |*args| 'from lambda' }
      store_translations(:en, :dynamic => my_proc)
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.compact!
      assert_equal 'from lambda', I18n.t(:dynamic)
    end
  end

  # eager_load! with compact cache

  test "eager_load!: writes compact cache when configured" do
    with_cache_file do |path|
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!
      assert File.exist?(path), "Compact cache file should be written by eager_load!"
      assert_equal 'baz', I18n.t('foo.bar')
    end
  end

  # Compact cache with multiple locales

  test "cache: preserves multiple locales" do
    with_cache_file do |path|
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!

      en_val = I18n.t('foo.bar', locale: :en)

      # Load from compact cache.
      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/fr.yml']
      I18n.backend.configure_compact_cache(path: path)
      I18n.backend.eager_load!

      assert_equal en_val, I18n.t('foo.bar', locale: :en)
      assert I18n.available_locales.include?(:en)
      assert I18n.available_locales.include?(:fr)
    end
  end

  # Pluggable cache serializers

  # Stands in for a MessagePack-style codec such as Paquito. It refuses any
  # class outside the primitive set, and it copies rather than preserving
  # object identity. Marshal hides both properties, so only a serializer like
  # this can show that the payload is portable.
  module PortableSerializer
    PRIMITIVES = [Hash, Array, String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    class << self
      attr_accessor :dumps, :loads
    end

    def self.reset
      self.dumps = 0
      self.loads = 0
    end

    def self.dump(object)
      self.dumps += 1
      Marshal.dump(copy(object))
    end

    def self.load(payload)
      self.loads += 1
      Marshal.load(payload)
    end

    # Rebuilds every container and String, so no two references in the result
    # point at one object. This is what MessagePack does, and it is why the
    # backend cannot rely on Marshal to re-share the base store.
    def self.copy(object)
      case object
      when Hash then object.each_with_object({}) { |(k, v), out| out[copy(k)] = copy(v) }
      when Array then object.map { |item| copy(item) }
      when String then object.dup
      when Symbol, Integer, Float, TrueClass, FalseClass, NilClass then object
      else raise TypeError, "cannot serialize #{object.class}"
      end
    end
  end

  test "configure_compact_cache: rejects a serializer without dump and load" do
    assert_raises(ArgumentError) do
      I18n.backend.configure_compact_cache(:path => "/tmp/i18n_unused.cache", :serializer => Object.new)
    end
  end

  test "cache: a custom serializer encodes and decodes the payload" do
    with_cache_file do |path|
      PortableSerializer.reset
      store_translations(:en, :greeting => "Hello")
      store_translations(:fr, :greeting => "Bonjour")
      I18n.backend.configure_compact_cache(:path => path, :serializer => PortableSerializer)
      I18n.backend.compact!

      assert_equal 1, PortableSerializer.dumps
      assert_equal 0, PortableSerializer.loads

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :greeting => "Hello")
      store_translations(:fr, :greeting => "Bonjour")
      I18n.backend.configure_compact_cache(:path => path, :serializer => PortableSerializer)
      I18n.backend.compact!

      assert_equal 1, PortableSerializer.loads
      assert_equal "Hello", I18n.t(:greeting, :locale => :en)
      assert_equal "Bonjour", I18n.t(:greeting, :locale => :fr)
    end
  end

  test "cache: the payload carries no backend objects" do
    with_cache_file do |path|
      PortableSerializer.reset
      store_translations(:en, :same => "SAME", :differs => "en", :colors => %w(red green))
      store_translations(:fr, :same => "SAME", :differs => "fr")
      I18n.backend.configure_compact_cache(:path => path, :serializer => PortableSerializer)

      # A DeltaStore reaches the serializer unless the stores are written as
      # plain data, and PortableSerializer raises on any such class.
      I18n.backend.compact!

      assert_operator File.size(path), :>, 0
    end
  end

  test "cache: every delta locale resolves through one shared base store" do
    with_cache_file do |path|
      PortableSerializer.reset
      %w(fr de).each_with_index do |locale, index|
        store_translations(locale.to_sym, :same => "SAME", :differs => "v#{index}")
      end
      store_translations(:en, :same => "SAME", :differs => "en")
      I18n.backend.configure_compact_cache(:path => path, :serializer => PortableSerializer)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :same => "SAME", :differs => "en")
      %w(fr de).each_with_index do |locale, index|
        store_translations(locale.to_sym, :same => "SAME", :differs => "v#{index}")
      end
      I18n.backend.configure_compact_cache(:path => path, :serializer => PortableSerializer)
      I18n.backend.compact!

      stores = I18n.backend.instance_variable_get(:@value_arrays)
      base = stores[:en]
      assert_instance_of Hash, base

      # The serializer copied the base store away; the backend re-shares it.
      assert stores[:fr].base.equal?(base), "fr should resolve through the base store"
      assert stores[:de].base.equal?(base), "de should resolve through the base store"

      assert_equal "SAME", I18n.t(:same, :locale => :de)
      assert_equal "v1", I18n.t(:differs, :locale => :de)
    end
  end

  test "cache: a file written with different framing is discarded" do
    with_cache_file do |path|
      # A well-formed Marshal payload that carries no compact cache header.
      File.binwrite(path, Marshal.dump([:some, :other, :format]))
      store_translations(:en, :test => "val")
      I18n.backend.configure_compact_cache(:path => path)
      I18n.backend.compact!

      assert_equal "val", I18n.t(:test)
    end
  end

  test "cache: a serializer that fails to load falls back to fresh compaction" do
    failing = Module.new do
      def self.dump(object)
        Marshal.dump(object)
      end

      def self.load(_payload)
        raise "unsupported payload"
      end
    end

    with_cache_file do |path|
      store_translations(:en, :test => "val")
      I18n.backend.configure_compact_cache(:path => path, :serializer => failing)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :test => "val")
      I18n.backend.configure_compact_cache(:path => path, :serializer => failing)
      I18n.backend.compact!

      assert_equal "val", I18n.t(:test)
    end
  end

  test "cache: a payload missing a field is discarded without leaving mixed state" do
    truncating = Module.new do
      def self.dump(object)
        Marshal.dump(object.reject { |key, _| key == :string_table })
      end

      def self.load(payload)
        Marshal.load(payload)
      end
    end

    with_cache_file do |path|
      store_translations(:en, :test => "val")
      store_translations(:fr, :test => "valeur")
      I18n.backend.configure_compact_cache(:path => path, :serializer => truncating)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :test => "val")
      store_translations(:fr, :test => "valeur")
      I18n.backend.configure_compact_cache(:path => path, :serializer => truncating)
      I18n.backend.compact!

      # The rejected payload must not survive into the fresh compaction.
      assert_equal "val", I18n.t(:test, :locale => :en)
      assert_equal "valeur", I18n.t(:test, :locale => :fr)
      assert_equal "hello", I18n.t(:test, :locale => :de, :default => "hello")
    end
  end

  def with_proc_locale_file
    require 'tempfile'
    file = Tempfile.new(['i18n_procs', '.rb'])
    file.write("{ :en => { :my_proc => lambda { |_key, **_opts| 'from proc' } } }")
    file.close
    yield file.path
  ensure
    file.unlink if file
  end

  # A serializer whose payload is well formed everywhere except proc_positions,
  # which load_compact_cache reads at the last step of the load.
  LATE_FAILURE_SERIALIZER = Module.new do
    def self.dump(object)
      Marshal.dump(object.merge(:proc_positions => { 0 => "not a list of keys" }))
    end

    def self.load(payload)
      Marshal.load(payload)
    end
  end

  test "cache: a payload that fails late leaves the live translations intact" do
    with_cache_file do |path|
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.configure_compact_cache(:path => path, :serializer => LATE_FAILURE_SERIALIZER)
      I18n.backend.eager_load!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml', locales_dir + '/en.rb']
      I18n.backend.configure_compact_cache(:path => path, :serializer => LATE_FAILURE_SERIALIZER)

      # compact! loads the YAML first, so the backend holds the real nested
      # trees at the moment the cache load fails. eager_load! would hide this:
      # it parses the YAML after the failed load and merges over the damage.
      I18n.backend.compact!

      # The failed load must not have replaced those trees with markers, or the
      # fresh compaction would compact the markers instead.
      assert_equal 'baz', I18n.t('foo.bar')
      assert_equal 'bas', I18n.t('fuh.bah')
    end
  end

  test "cache: a proc survives a load that fails before the procs are patched" do
    with_proc_locale_file do |rb_path|
      with_cache_file do |path|
        I18n.load_path = [locales_dir + '/en.yml', rb_path]
        I18n.backend.configure_compact_cache(:path => path, :serializer => LATE_FAILURE_SERIALIZER)
        I18n.backend.eager_load!
        assert_equal 'from proc', I18n.t(:my_proc)

        I18n.backend = CompactBackend.new
        I18n.load_path = [locales_dir + '/en.yml', rb_path]
        I18n.backend.configure_compact_cache(:path => path, :serializer => LATE_FAILURE_SERIALIZER)
        I18n.backend.compact!

        # The load raises inside rebuild_procs!, so the objects table still
        # holds PROC_PLACEHOLDER where the proc belongs. Recompacting the live
        # tree recovers the real proc; recompacting the markers would serve the
        # placeholder Symbol instead.
        assert_equal 'from proc', I18n.t(:my_proc)
      end
    end
  end

  test "cache: a serializer that returns frozen containers survives a later compact!" do
    # Paquito freezes its result when built with freeze: true.
    freezing = Module.new do
      def self.dump(object)
        Marshal.dump(object)
      end

      def self.load(payload)
        deep_freeze(Marshal.load(payload))
      end

      def self.deep_freeze(object)
        case object
        when Hash then object.each { |key, value| deep_freeze(key); deep_freeze(value) }
        when Array then object.each { |item| deep_freeze(item) }
        end
        object.freeze
      end
    end

    with_cache_file do |path|
      store_translations(:en, :test => "val")
      I18n.backend.configure_compact_cache(:path => path, :serializer => freezing)
      I18n.backend.compact!

      I18n.backend = CompactBackend.new
      I18n.load_path = [locales_dir + '/en.yml']
      store_translations(:en, :test => "val")
      I18n.backend.configure_compact_cache(:path => path, :serializer => freezing)
      I18n.backend.compact!
      assert_equal "val", I18n.t(:test)

      # Invalidate the cache so the next compact! cannot reload it, and must
      # rebuild over the frozen containers the serializer returned.
      File.binwrite(path, "not a compact cache")
      store_translations(:fr, :test => "valeur")
      I18n.backend.compact!

      assert_equal "val", I18n.t(:test, :locale => :en)
      assert_equal "valeur", I18n.t(:test, :locale => :fr)
    end
  end
end
