require 'test_helper'

class I18nBackendLazyLoadTest < I18n::TestCase
  def setup
    super

    @lazy_mode_backend = I18n::Backend::LazyLoad.new(lazy_load: true)
    @eager_mode_backend = I18n::Backend::LazyLoad.new(lazy_load: false)

    I18n.load_path = [File.join(locales_dir, '/en.yml'), File.join(locales_dir,  '/fr.yml')]
  end

  test "lazy mode: only loads translations for current locale" do
    with_lazy_mode do
      @backend.reload!

      assert_nil translations

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" }}}, translations)
    end
  end

  test "lazy mode: merges translations for current locale with translations already existing in memory" do
    with_lazy_mode do
      @backend.reload!

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" }}}, translations)

      I18n.with_locale(:fr) { I18n.t("animal.dog") }
      assert_equal({ en: { foo: { bar: "baz" } }, fr: { animal: { dog: "chien" } } }, translations)
    end
  end

  test "lazy mode: #initialized? responds based on whether current locale is initialized" do
    with_lazy_mode do
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
  end

  test "lazy mode: reload! uninitializes all locales" do
    with_lazy_mode do
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
  end

  test "lazy mode: eager_load! raises UnsupportedMethod exception" do
    with_lazy_mode do
      exception = assert_raises(I18n::UnsupportedMethod) { @backend.eager_load! }
      assert_equal "I18n::Backend::LazyLoad does not support the #eager_load! method", exception.message
    end
  end

  test "lazy mode: loads translations from files that start with current locale identifier or contain identifier in path components, and end with a supported extension" do
    with_lazy_mode do
      file_contents = { en: { alice: "bob" } }.to_yaml

      invalid_files = [
        { filename: ['translation', '.yml'] },                # No locale identifier
        { filename: ['en_translation', '.unsupported'] },     # Unsupported extension
        { filename: ['translation', '.unsupported'] },        # No locale identifier and unsupported extension
      ]

      invalid_files.each do |file|
        with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
          I18n.with_locale(:en) { I18n.t("foo.bar") }
          assert_equal({ en: { foo: { bar: "baz" }}}, translations)
        end
      end

      valid_files = [
        { filename: ['en_translation', '.yml'] },         # Contains locale identifier with correct demarcation, and supported extension
        { filename: ['en_', '.yml'] },                    # Path component matches locale identifier exactly
      ]

      valid_files.each do |file|
        with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
          I18n.with_locale(:en) { I18n.t("foo.bar") }
          assert_equal({ en: { foo: { bar: "baz" }, alice: "bob" }}, translations)
        end
      end
    end
  end

  test "lazy mode: #available_locales returns all locales available from load path irrespective of current locale" do
    with_lazy_mode do
      I18n.with_locale(:en) { assert_equal [:en, :fr], @backend.available_locales }
      I18n.with_locale(:fr) { assert_equal [:en, :fr], @backend.available_locales }
    end
  end

  test "eager mode: load all translations, irrespective of locale" do
    with_eager_mode do
      @backend.reload!

      assert_nil translations

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" } }, fr: { animal: { dog: "chien" } } }, translations)
    end
  end

  test "eager mode: raises error if locales loaded cannot be extracted from load path names" do
    with_eager_mode do
      @backend.reload!

      contents = { de: { cat: 'katze' } }.to_yaml

      with_translation_file_in_load_path(['translation', '.yml'], nil, contents) do |file_path|
        exception = assert_raises(I18n::InvalidFilenames) { I18n.t("foo.bar") }
        assert_equal "Locales cannot be extracted from the following paths: #{[file_path]}", exception.message
      end
    end
  end

  private

  def with_lazy_mode
    @backend = I18n.backend = @lazy_mode_backend

    yield
  end

  def with_eager_mode
    @backend = I18n.backend = @eager_mode_backend

    yield
  end


  def with_translation_file_in_load_path(name, tmpdir, file_contents)
    @backend.reload!

    path_to_dir = FileUtils.mkdir_p(File.join(Dir.tmpdir, tmpdir)).first if tmpdir
    locale_file = Tempfile.new(name, path_to_dir)

    locale_file.write(file_contents)
    locale_file.rewind

    I18n.load_path << locale_file.path

    yield(locale_file.path)

    I18n.load_path.delete(locale_file.path)
  end
end

