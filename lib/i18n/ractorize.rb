# frozen_string_literal: true

require "i18n"

I18n.eager_load!

Ractor.make_shareable(I18n.config.backend)
