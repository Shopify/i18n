require 'test_helper'

class I18nCompactBackendWithSimpleApiTest < I18n::TestCase
  include I18n::Tests::Basics
  include I18n::Tests::Defaults
  include I18n::Tests::Interpolation
  include I18n::Tests::Link
  include I18n::Tests::Lookup
  include I18n::Tests::Pluralization
  include I18n::Tests::Procs
  include I18n::Tests::Localization::Date
  include I18n::Tests::Localization::DateTime
  include I18n::Tests::Localization::Time
  include I18n::Tests::Localization::Procs

  class CompactBackend < I18n::Backend::Simple
    include I18n::Backend::Compact
  end

  def setup
    I18n.backend = CompactBackend.new
    super
  end

  test "make sure we use the CompactBackend backend" do
    assert_equal CompactBackend, I18n.backend.class
  end
end
