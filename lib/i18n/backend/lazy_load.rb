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
    # c1) the filename starts with the locale identifier
    #    OR
    # c2) the path contains a component equal to the locale identifier
    #
    # Examples:
    # Valid files that will be selected by this backend:
    #
    # "files/locales/en-translation.yml" (Selected for locale "en")
    # "files/locales/fr/translation.po"  (Selected for locale "fr")
    #
    # Invalid files that won't be selected by this backend:
    #
    # "files/locales/translation-file"
    # "files/locales/en-translation.unsupported"
    # "files/locales/french/translation.yml"
    #
    # The implementation uses this assumption to defer the loading of
    # translation files until the current locale actually requires them.
    #
    # Note: This backend isn't designed for production environments or other
    # environments where eager loading all translations is recommended.
    #
    # To use the LazyLoad backend instantiate it and set it to the I18n module.
    # You can configure lazy loaded backends through the initializer or backends
    # accessor:
    #
    #   # configure I18n backend to use LazyLoad Backend
    #   I18n.backend = I18n::Backend::LazyLoad.new
    #
    class LazyLoad < Simple
      # Returns whether the current locale is initialized.
      def initialized?
        initialized_locales[I18n.locale]
      end

      # Clean up translations and uninitialize all locales.
      def reload!
        @initialized_locales = nil
        @translations = nil
      end

      def eager_load!
        raise UnsupportedMethod.new(__method__, self.class)
      end

      protected

      # Load translations from files that belong to the current locale.
      def init_translations
        load_translations(filenames_for_current_locale)
        initialized_locales[I18n.locale] = true
      end

      def initialized_locales
        @initialized_locales ||= Hash.new(false)
      end

      # Select all files from I18n load path that belong to current locale.
      # These files must start with the locale identifier (ie. "en", "fr").
      # or contain a path component equal to the locale identifier (ie. /locales/en/translation.yml)
      def filenames_for_current_locale
        I18n.load_path.flatten.select do |path|
          (basename_starts_with_locale?(path) || path_contains_locale_identifier?(path)) &&
          supported_extension?(path)
        end
      end

      SUPPORTED_EXTENSIONS = [".yml", ".yaml", ".po", ".json", ".rb"].freeze

      def supported_extension?(path)
        path.end_with?(*SUPPORTED_EXTENSIONS)
      end

      def basename_starts_with_locale?(path)
        File.basename(path).start_with?(I18n.locale.to_s)
      end

      def path_contains_locale_identifier?(path)
        Pathname.new(path).each_filename.any? { |component| component == I18n.locale.to_s }
      end
    end
  end
end
