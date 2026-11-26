require 'minitest/autorun'
load File.expand_path('../mod_loader/framework/input/keyboard.rb', __dir__)
# Numeric-prefix peers may load in either order; native dependencies are lazy.
load File.expand_path('../mod_loader/framework/input/line_input.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/text_input.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/clipboard.rb', __dir__)

module ModLoader
  def self.input_press?(*); false; end
  def self.input_trigger?(*); false; end
  def self.input_repeat?(*); false; end
end

class ModLoaderLineInputTest < Minitest::Test
  T = ModLoader::TextInput
  K = ModLoader::Keyboard

  def setup
    @line = T::Line.new
  end

  def update(keys, repeats = keys, character = '')
    ModLoader.stub(:input_press?, proc { |key| keys.include?(key) }) do
      ModLoader.stub(:input_trigger?, proc { |key| keys.include?(key) }) do
        ModLoader.stub(:input_repeat?, proc { |key| repeats.include?(key) }) do
          T.stub(:character, character) { T.update(@line) }
        end
      end
    end
  end

  def test_limit_counts_characters_and_insertion_preserves_the_suffix
    @line = T::Line.new(:max_length => 4)
    @line.replace('Я!')
    @line.seek(1)
    @line.insert('😀юлишнее')
    assert_equal 'Я😀ю!', @line.text
    assert_equal 3, @line.cursor
    revision = @line.revision
    @line.insert('x')
    assert_equal revision, @line.revision
    @line.delete
    @line.insert('z')
    assert_equal 'Я😀юz', @line.text
    @line.replace('😀' * 10)
    assert_equal '😀' * 4, @line.text
    assert_equal 4, @line.cursor
  end

  def test_revision_tracks_text_and_caret_but_ignores_no_ops
    revision = @line.revision
    @line.backspace.delete.seek(-10).seek(10).insert('').replace('')
    assert_equal revision, @line.revision
    @line.replace('aя😀')
    assert_equal revision + 1, @line.revision
    @line.seek(1)
    assert_equal revision + 2, @line.revision
    @line.replace('aя😀')
    assert_equal 3, @line.cursor
    assert_equal revision + 3, @line.revision
  end

  def test_draft_does_not_alias_history_or_allow_edits_outside_the_editor
    history = 'команда'
    @line.replace(history)
    snapshot = @line.text
    @line.seek(0)
    @line.insert('!')
    assert_equal 'команда', history
    assert_equal 'команда', snapshot
    assert snapshot.frozen?
    refute history.frozen?
    history.replace('changed')
    assert_equal '!команда', @line.text
  end

  def test_multiline_clipboard_text_becomes_one_line_without_losing_unicode
    @line.replace('[]')
    @line.seek(1)
    @line.insert("я😀\r\nx\ry\nz\t\0\x01")
    assert_equal '[я😀 x y z ]', @line.text
    assert_equal @line.text.length - 1, @line.cursor
  end

  def test_view_follows_cursor_font_width_and_resize_without_editing_the_text
    @line.replace('Wiя😀')
    measure = proc { |text| text.each_char.map { |char| { 'W' => 15, 'i' => 3, 'я' => 11, '😀' => 18 }[char] }.inject(0, :+) }
    revision = @line.revision
    assert_equal ['😀', 18], @line.view(20, &measure)
    assert_equal revision, @line.revision
    @line.seek(0)
    assert_equal ['Wi', 0], @line.view(20, &measure)
    @line.seek(2)
    assert_equal ['Wi', 18], @line.view(20, &measure)
    assert_equal ['i', 3], @line.view(10, &measure)
    assert_equal ['Wiя😀', 18], @line.view(60, &measure)
    assert_equal ['', 0], @line.view(0, &measure)
    assert_equal 'Wiя😀', @line.text
  end

  def test_keyboard_consumes_editing_boundaries_and_leaves_owner_keys_alone
    refute update([K::RETURN, K::ESC, K::UP, K::DOWN, K::PRIOR, K::NEXT, K::F9])
    assert update([K::LEFT])
    assert_equal 0, @line.revision
    @line.replace('абв')
    assert update([], [K::LEFT]) # repeat without a fresh trigger
    assert_equal 2, @line.cursor
    assert update([], [K::BACK])
    assert_equal 'ав', @line.text
  end

  def test_clipboard_shortcuts_consume_the_frame_even_when_nothing_changes
    @line.replace('команда')
    @line.seek(2)
    revision = @line.revision
    copied = []
    ModLoader::Clipboard.stub(:write, proc { |text| copied << text }) do
      assert update([K::CTRL, K::C, K::RETURN], [], 'c')
    end
    assert_equal ['команда'], copied
    ModLoader::Clipboard.stub(:read, nil) { assert update([K::CTRL, K::V, K::RETURN], [], 'v') }
    assert_equal revision, @line.revision
    ModLoader::Clipboard.stub(:read, '😀') { assert update([K::CTRL, K::V, K::RETURN], [], 'v') }
    assert_equal 'ко😀манда', @line.text
    assert_equal 3, @line.cursor
  end

  def test_altgr_goes_through_layout_conversion_instead_of_clipboard_shortcuts
    ModLoader::Clipboard.stub(:read, proc { flunk 'AltGr must not read the clipboard' }) do
      assert update([K::CTRL, K::ALT, K::V], [], '@')
    end
    assert_equal '@', @line.text
  end
end
