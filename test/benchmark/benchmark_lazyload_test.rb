require 'test_helper'
require 'benchmark'
require 'securerandom'

class BenchmarkLazyLoadTest < I18n::TestCase
  test "lazy load performance" do
    benchmark(backend: I18n::Backend::LazyLoad.new)
  end

  test "simple performance" do
    benchmark(backend: I18n::Backend::Simple.new)
  end

  def benchmark(backend:)
    @backend = I18n.backend = backend
    @backend.reload!

    en_files = create_temp_translation_files(locale: "en", num_files: 100, num_keys: 1000)
    fr_files = create_temp_translation_files(locale: "fr", num_files: 100, num_keys: 1000)
    de_files = create_temp_translation_files(locale: "de", num_files: 100, num_keys: 1000)

    Benchmark.bm do |x|
      puts "\n"
      x.report(@backend.class) do
        I18n.with_locale(:en) { I18n.t("1.1") }
      end
    end

    remove_tempfiles(en_files)
    remove_tempfiles(fr_files)
    remove_tempfiles(de_files)
  end

  def create_temp_translation_files(locale:, num_files:, num_keys:)
    paths = []
    num_files.times do |file_num|
      path = File.join(Dir.tmpdir, "#{locale}-#{SecureRandom.uuid}.yml")
      File.write(path, generate_random_file_content(locale, num_keys, file_num))

      paths << path
      I18n.load_path << path
    end
    paths
  end

  def generate_random_file_content(locale, num_keys, file_num)
    content = {}
    num_keys.times do |key_num|
      content["#{file_num}-#{key_num}"] = SecureRandom.alphanumeric
    end

    { locale => content }.to_yaml
  end

  def remove_tempfiles(paths)
    paths.each do |path|
      I18n.load_path.delete(path)
      File.delete(path) if File.exist?(path)
    end
  end
end
