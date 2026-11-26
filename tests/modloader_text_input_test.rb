require 'minitest/autorun'
load File.expand_path('../mod_loader/framework/input/text_input.rb', __dir__)

class ModLoaderTextInputTest < Minitest::Test
  T = ModLoader::TextInput
  def convert(value, count = nil, keyboard_ok = true)
    state = Object.new
    state.define_singleton_method(:call) { |buffer| keyboard_ok ? 1 : 0 }
    converter = Object.new
    converter.define_singleton_method(:call) do |key, scan, keyboard, output, size, flags|
      raise 'conversion after keyboard failure' unless keyboard_ok
      bytes = value.encode('UTF-16LE').b
      output[0, bytes.bytesize] = bytes
      count || bytes.bytesize / 2
    end
    T.instance_variable_set(:@state_api, state)
    T.instance_variable_set(:@text_api, converter)
    T.character(0x41)
  ensure
    T.instance_variable_set(:@state_api, nil)
    T.instance_variable_set(:@text_api, nil)
  end

  def test_cyrillic_and_surrogate_pairs_are_utf8
    ['я', 'Я', 'Q', 'é', '😀'].each do |value|
      result = convert(value)
      assert_equal value, result
      assert_equal Encoding::UTF_8, result.encoding
    end
  end

  def test_dead_keys_and_noncharacters_produce_no_text
    assert_equal '', convert('', -1)
    assert_equal '', convert('', 0)
  end

  def test_control_characters_stay_with_the_editor
    assert_equal '', convert("\r")
    assert_equal '', convert("\b")
    assert_equal ' ', convert(' ')
  end

  def test_unavailable_keyboard_state_does_not_invoke_conversion
    assert_equal '', convert('A', nil, false)
  end
end
