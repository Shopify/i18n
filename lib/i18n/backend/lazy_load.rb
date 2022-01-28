# frozen_string_literal: true

module I18n
  module Backend
    # Backend that lazy loads translations based on the current locale. This
    # implementation avoids loading all translations up front. Instead, it only
    # loads the translations that belong to the current locale. This offers a
    # performance incentive in local development and test environments for
    # applications with many translations for many different locales. It's
    # particularly useful when the application only refers to a single locales'
    # translations at a time (ex. A Rails workload).  The implementation
    # identifies which translation files from the load path belong to the
    # current locale by pattern matching against their path name.
    #
    # Specifically, a translation file is considered to belong to a locale if:
    # a) the filename is in the I18n load path
    # b) the filename ends in a supported extension (ie. .yml, .json, .po, .rb)
    # c) the filename starts with the locale identifier
    # d) the locale identifier and optional proceeding text is separated by an underscore, ie. "_".
    #
    # Examples:
    # Valid files that will be selected by this backend:
    #
    # "files/locales/en_translation.yml" (Selected for locale "en")
    # "files/locales/fr.po"  (Selected for locale "fr")
    #
    # Invalid files that won't be selected by this backend:
    #
    # "files/locales/translation-file"
    # "files/locales/en-translation.unsupported"
    # "files/locales/french/translation.yml"
    # "files/locales/fr/translation.yml"
    #
    # The implementation uses this assumption to defer the loading of
    # translation files until the current locale actually requires them.
    #
    # The backend has two working modes: lazy_load and eager_load.
    #
    # This is configured using I18n.lazy_loadable_backed.lazy_load
    # which defaults to false.
    #
    # We recommend enabling this to true in test environments only.
    # When the mode is set to false, the backend behaves exactly like the
    # Simple backend, with an additional check that the paths being loaded
    # abide by the format. If paths can't be matched to the format, an error is raised.
    #
    # You can configure lazy loaded backends through the initializer or backends
    # accessor:
    #
    #   # In test environments
    #
    #   I18n.lazy_loadable_backend.lazy_load = true
    #   I18n.backend = I18n::Backend::LazyLoad.new
    #
    #   # In other environments, such as Prod and CI
    #
    #   I18n.lazy_loadable_backend.lazy_load = false # default
    #   I18n.backend = I18n::Backend::LazyLoad.new
    #
    class LocaleExtractor
      class << self
        def locale_from_path(path)
          name = File.basename(path, ".*")
          locale = name.split("_").first
          locale.to_sym unless locale.nil?
        end
      end
    end

    class LazyLoad < Simple
      def initialize(lazy_load: false)
        @lazy_load = lazy_load
      end

      # Returns whether the current locale is initialized.
      def initialized?
        if lazy_load?
          initialized_locales[I18n.locale]
        else
          super
        end
      end

      # Clean up translations and uninitialize all locales.
      def reload!
        if lazy_load?
          @initialized_locales = nil
          @translations = nil
        else
          super
        end
      end

      # Eager loading is not supported in the lazy context.
      def eager_load!
        if lazy_load?
          raise UnsupportedMethod.new(__method__, self.class)
        else
          super
        end
      end

      # Select all files from I18n load path that belong to current locale.
      # These files must start with the locale identifier (ie. "en", "pt-BR"),
      # followed by an "_" demarcation to separate proceeding text.
      def filenames_for_current_locale
        I18n.load_path.flatten.select do |path|
          LocaleExtractor.locale_from_path(path) == I18n.locale &&
          supported_extension?(path)
        end
      end

      # Parse the load path and extract all locales.
      def available_locales
        if lazy_load?
          I18n.load_path.map { |path| LocaleExtractor.locale_from_path(path) }
        else
          super
        end
      end

      protected

      # Load translations from files that belong to the current locale.
      def init_translations
        if lazy_load?
          load_translations(filenames_for_current_locale)
          initialized_locales[I18n.locale] = true
        else
          super
          filenames_named_incorrectly = I18n.load_path.reject { |path| file_named_correctly?(path) }
          raise InvalidFilenames.new(filenames_named_incorrectly) unless filenames_named_incorrectly.empty?
        end
      end

      def initialized_locales
        @initialized_locales ||= Hash.new(false)
      end

      private

      def lazy_load?
        @lazy_load
      end

      SUPPORTED_EXTENSIONS = [".yml", ".yaml", ".po", ".json", ".rb"].freeze

      def supported_extension?(path)
        path.end_with?(*SUPPORTED_EXTENSIONS)
      end

      def file_named_correctly?(path)
        extracted_locale = LocaleExtractor.locale_from_path(path)
        available_locales.include?(extracted_locale)
      end
    end
  end
end
