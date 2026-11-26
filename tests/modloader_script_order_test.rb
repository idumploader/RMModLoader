require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
resetter = File.expand_path('../mod_loader/framework/core/resetter.rb', __dir__)
# Ordering tests do not snapshot or modify Ruby's engine/global classes.
eval(File.read(resetter).split("\nModResetter.snapshot_all_if_needed").first + "\nend\n", TOPLEVEL_BINDING, resetter)
module ModLoader; end

class ModLoaderScriptOrderTest < Minitest::Test
  def test_grouped_names_reload_in_native_order_including_ties_and_invalid_names
    Dir.mktmpdir do |directory|
      scripts = File.join(directory, 'scripts')
      Dir.mkdir(scripts)
      ModLoader.define_singleton_method(:data_directory) { directory }
      # Creation order intentionally puts dependent runtime and invalid names first.
      names = ['zzz.rb', '990 - ModLoader Runtime.rb', '245 - ModLoader Z Backend.rb',
               '1 - ModLoader Core.rb', '245 - ModLoader A Backend.rb',
               '1040 - ModLoader HTTP.rb', 'aaa.rb']
      names.each do |name|
        source = "$script_order_fixture << #{name.inspect}\n"
        source = "raise 'core not loaded' unless $script_order_fixture.include?('1 - ModLoader Core.rb')\n" + source if name.start_with?('990')
        File.write(File.join(scripts, name), source)
      end
      Dir.mkdir(File.join(scripts, '0 - Directory.rb'))
      File.write(File.join(scripts, '0 - Disabled.rb.disabled'), 'raise "disabled file ran"')
      expected = ['1 - ModLoader Core.rb', '245 - ModLoader A Backend.rb',
                  '245 - ModLoader Z Backend.rb', '990 - ModLoader Runtime.rb',
                  '1040 - ModLoader HTTP.rb', 'aaa.rb', 'zzz.rb']
      2.times do
        $script_order_fixture = []
        output, = capture_io { ModResetter.execute_all_scripts }
        refute_includes output, 'Failed to execute script'
        assert_equal expected, $script_order_fixture
      end
    ensure
      ModLoader.singleton_class.send(:remove_method, :data_directory)
      $script_order_fixture = nil
    end
  end
  def test_signed_int64_prefix_matches_native_stream_parser
    maximum = (1 << 63) - 1
    assert_equal(-12, ModResetter.script_priority('-12 - Negative.rb'))
    assert_equal maximum, ModResetter.script_priority('9223372036854775807 - Maximum.rb')
    assert_equal(-(1 << 63), ModResetter.script_priority('-9223372036854775808 - Minimum.rb'))
    assert_equal 12, ModResetter.script_priority(' +12suffix - Prefix.rb')
    assert_equal maximum, ModResetter.script_priority('9223372036854775808 - Overflow.rb')
    assert_equal maximum, ModResetter.script_priority('-9223372036854775809 - Underflow.rb')
    assert_equal maximum, ModResetter.script_priority('12- Missing delimiter.rb')
    assert_equal maximum, ModResetter.script_priority('not a number - Name.rb')
  end
end
