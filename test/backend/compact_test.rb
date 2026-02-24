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
end
