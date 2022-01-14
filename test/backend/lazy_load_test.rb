require 'test_helper'

class I18nBackendLazyLoadTest < I18n::TestCase
  def setup
    super
    @backend  = I18n.backend = I18n::Backend::LazyLoad.new
    I18n.load_path = [File.join(locales_dir, '/en.yml'), File.join(locales_dir,  '/fr.yml')]
  end

  test "only loads translations for current locale" do
    @backend.reload!

    assert_nil translations

    I18n.with_locale(:en) { I18n.t("foo.bar") }
    assert_equal({ en: { foo: { bar: "baz" }}}, translations)
  end

  test "merges translations for current locale with translations already existing in memory" do
    @backend.reload!

    I18n.with_locale(:en) { I18n.t("foo.bar") }
    assert_equal({ en: { foo: { bar: "baz" }}}, translations)

    I18n.with_locale(:fr) { I18n.t("animal.dog") }
    assert_equal({ en: { foo: { bar: "baz" } }, fr: { animal: { dog: "chien" } } }, translations)
  end

  test "#initialized? responds based on whether current locale is initialized" do
    @backend.reload!

    I18n.with_locale(:en) do
      refute_predicate @backend, :initialized?
      I18n.t("foo.bar")
      assert_predicate @backend, :initialized?
    end

    I18n.with_locale(:fr) do
      refute_predicate @backend, :initialized?
    end
  end

  test "reload! uninitializes all locales" do
    I18n.with_locale(:en) { I18n.t("foo.bar") }
    I18n.with_locale(:fr) { I18n.t("animal.dog") }

    @backend.reload!

    I18n.with_locale(:en) do
      refute_predicate @backend, :initialized?
    end

    I18n.with_locale(:fr) do
      refute_predicate @backend, :initialized?
    end
  end

  test "eager_load! raises UnsupportedMethod exception" do
    exception = assert_raises(I18n::UnsupportedMethod) { @backend.eager_load! }
    assert_equal "I18n::Backend::LazyLoad does not support the #eager_load! method", exception.message
  end

  test "loads translations from files that start with current locale identifier or contain identifier in path components, and end with a supported extension" do
    file_contents = { en: { alice: "bob" } }.to_yaml

    invalid_files = [
      { filename: ['translation', '.yml'] },                # No locale identifier
      { filename: ['en-translation', '.unsupported'] },     # Unsupported extension
      { filename: ['translation', '.unsupported'] },        # No locale identifier and unsupported extension
      { filename: ['translation', '.yml'], dir: 'english' } # Path component doesn't match locale identifier exactly ("english" != "en")
    ]

    invalid_files.each do |file|
      with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
        I18n.with_locale(:en) { I18n.t("foo.bar") }
        assert_equal({ en: { foo: { bar: "baz" }}}, translations)
      end
    end

    valid_files = [
      { filename: ['en-translation', '.yml'] },         # Contains locale identifier and supported extension
      { filename: ['translation', '.yml'], dir: 'en' }, # Path component matches locale identifier exactly
    ]

    valid_files.each do |file|
      with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
        I18n.with_locale(:en) { I18n.t("foo.bar") }
        assert_equal({ en: { foo: { bar: "baz" }, alice: "bob" }}, translations)
      end
    end
  end

  private

  def with_translation_file_in_load_path(name, tmpdir, file_contents)
    @backend.reload!

    path_to_dir = FileUtils.mkdir_p(File.join(Dir.tmpdir, tmpdir)).first if tmpdir
    locale_file = Tempfile.new(name, path_to_dir)

    locale_file.write(file_contents)
    locale_file.rewind

    I18n.load_path << locale_file.path

    yield

    I18n.load_path.delete(locale_file.path)
  end
end

