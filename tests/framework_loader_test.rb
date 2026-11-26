require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../mod_loader/framework/loader.rb', __dir__)

class FrameworkLoaderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @framework = File.join(@directory, 'framework')
    FileUtils.mkdir_p(File.join(@framework, 'example'))
    directory = @directory
    ModLoader.define_singleton_method(:data_directory) { directory }
    $framework_fixture_count = 0
  end
  def teardown
    ModLoader.singleton_class.send(:remove_method, :data_directory)
    FileUtils.remove_entry(@directory)
    $imported.delete('IDL-FrameworkFixture') if $imported
    $framework_fixture_count = $framework_fixture_file = $framework_fixture_text = nil
  end
  def test_native_directory_and_absolute_eval_filename
    path = File.join(@framework, 'example/component.rb')
    text = "\u043f\u0440\u0438\u0432\u0435\u0442"
    File.write(path, "$framework_fixture_file = __FILE__\n$framework_fixture_text = \"#{text}\"\n")
    ModLoader::Framework.load('example/component.rb')
    assert_equal File.expand_path(path), $framework_fixture_file
    assert_equal text, $framework_fixture_text
    assert_equal Encoding::UTF_8, $framework_fixture_text.encoding
  end
  def test_component_guard_controls_reloading_without_require_cache
    File.write(File.join(@framework, 'example/component.rb'), <<'RUBY')
$imported ||= {}
unless $imported['IDL-FrameworkFixture']
  $imported['IDL-FrameworkFixture'] = true
  $framework_fixture_count += 1
end
RUBY
    2.times { ModLoader::Framework.load('example/component.rb') }
    assert_equal 1, $framework_fixture_count
    $imported.delete('IDL-FrameworkFixture')
    ModLoader::Framework.load('example/component.rb')
    assert_equal 2, $framework_fixture_count
  end
end
