# frozen_string_literal: true

require "i18n"

I18n.eager_load!

I18n::Config.available_locales = I18n::Config.available_locales
Ractor.make_shareable(I18n::Config.backend)
Ractor.make_shareable(I18n::Config.available_locales)
Ractor.make_shareable(I18n::Config.available_locales_set)
Ractor.make_shareable(I18n::Config.exception_handler)
Ractor.make_shareable(I18n::Config.interpolation_patterns)
Ractor.make_shareable(I18n::Config.load_path)
# I18n.fallbacks= freezes shallowly so #map keeps working until boot ends; here it becomes deeply shareable.
Ractor.make_shareable(I18n.instance_variable_get(:@fallbacks)) if I18n.instance_variable_defined?(:@fallbacks)

config = I18n.config
config.available_locales_set
config.default_locale
config.default_separator
config.exception_handler
config.interpolation_patterns
config.load_path
config.owner = nil

Ractor.make_shareable(config)
