require 'test_helper'
require 'rbconfig'

# i18n/ractorize makes the configuration shareable for the rest of the
# process, so each test runs its script in a child Ruby and reads what it prints.
class I18nRactorTest < I18n::TestCase
  def setup
    super
    skip "needs Ruby 4.0+ (Ractor#value)" unless defined?(Ractor) && Ractor.method_defined?(:value)
  end

  test "I18n.fallbacks is readable from a non-main Ractor when it was never set" do
    assert_equal '[:"de-AT", :de]', run_script(<<~RUBY)
      require "i18n/backend/fallbacks"
      require "i18n/ractorize"
      Ractor.new { I18n.fallbacks[:"de-AT"].inspect }.value
    RUBY
  end

  test "I18n.fallbacks set at boot is readable from a non-main Ractor in a fiber with its own storage" do
    assert_equal '[:"de-AT", :de, :"en-GB", :en]', run_script(<<~RUBY)
      require "i18n/backend/fallbacks"
      I18n.fallbacks = I18n::Locale::Fallbacks.new(:"en-GB", :"de-AT" => :de)
      require "i18n/ractorize"
      Ractor.new { Fiber.new(storage: {}) { I18n.fallbacks[:"de-AT"].inspect }.resume }.value
    RUBY
  end

  test "I18n::INTERPOLATION_PATTERN is readable from a non-main Ractor" do
    assert_equal "true", run_script(<<~RUBY)
      require "i18n/ractorize"
      Ractor.new { I18n::INTERPOLATION_PATTERN.match?("%{name}").inspect }.value
    RUBY
  end

  private

  def run_script(script)
    lib = File.expand_path("../lib", __dir__)
    source = "require 'i18n'\nresult = begin\n#{script}\nend\nprint result"
    output = IO.popen([RbConfig.ruby, "-W0", "-rbundler/setup", "-I", lib, "-e", source], err: [:child, :out], &:read)
    assert $?.success?, output
    output
  end
end
