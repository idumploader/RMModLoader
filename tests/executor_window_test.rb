require_relative 'support/modmenu_rgss'

# Use real VK codes and the constructor's deactivate call: the old fixture
# skipped that call and could only exercise reopening an already allocated window.
ModLoader::Keyboard.constants(false).each { |name| ModLoader::Keyboard.send(:remove_const, name) }
load File.expand_path('../mod_loader/framework/input/keyboard.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/text_input.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/clipboard.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/line_input.rb', __dir__)
module ModLoader
  def self.version; '2.5'; end
end
class Font
  def self.default_size; 24; end
end
Color = Struct.new(:red, :green, :blue, :alpha)
Rect = Struct.new(:x, :y, :width, :height) do
  def initialize(x = 0, y = 0, width = 0, height = 0); super; end
end
class ExecutorTestContents
  attr_reader :width, :height, :font, :draws, :fills
  def initialize(width, height)
    @width, @height = width, height
    @font = OpenStruct.new(:size => 24, :color => Color.new(255, 255, 255, 255))
    @draws, @fills = [], []
  end
  def rect; Rect.new(0, 0, width, height); end
  def clear; @draws.clear; @fills.clear; end
  def fill_rect(*args); @fills << args; end
end
class Window_Base
  attr_accessor :openness
  alias executor_test_initialize initialize
  def initialize(*args)
    executor_test_initialize(*args)
    @contents = ExecutorTestContents.new(contents_width, contents_height)
    @openness = 255
  end
  def contents_width; width - 24; end
  def contents_height; height - 24; end
  def contents; @contents; end
  def open; @openness = 255; self; end
  def close; @openness = 0; self; end
  def open?; @openness == 255; end
  def draw_text(*args)
    rect = args.first.is_a?(Rect) ? args.shift.dup : Rect.new(*args.shift(4))
    contents.draws << [rect, *args]
  end
  def text_size(text)
    width = text.each_char.map { |char| { 'i' => 3, 'W' => 15, 'я' => 11, '😀' => 18 }[char] || 10 }.inject(0, :+)
    Rect.new(0, 0, width, contents.font.size)
  end
end
class Window_Selectable < Window_Base
  def initialize(*args)
    super
    @index = -1
    deactivate
  end
  def contents_height; [super - super % line_height, line_height].max; end
end
class Scene_MenuBase < Scene_Base; end
load File.expand_path('../mod_loader/framework/console/executor_scene.rb', __dir__)

class ExecutorWindowTest < Minitest::Test
  K = ModLoader::Keyboard
  C = ModLoader::InputCapture

  def test_framework_component_preserves_guard_on_reload
    implementation = File.expand_path('../mod_loader/framework/console/executor_scene.rb', __dir__)
    execute = ExecutorEnvironment.method(:execute)
    initialize_window = Executor_Window.instance_method(:initialize)
    history = ExecutorModule::COMMANDS_HISTORY
    assert_equal implementation, execute.source_location.first
    assert_equal implementation, initialize_window.source_location.first

    load File.expand_path('../mod_loader/framework/console/executor_scene.rb', __dir__)
    assert_equal execute, ExecutorEnvironment.method(:execute)
    assert_equal initialize_window, Executor_Window.instance_method(:initialize)
    assert_same history, ExecutorModule::COMMANDS_HISTORY
    assert_equal '1.0', $imported['IDL-ExecutorScene']
  end

  def setup
    ModLoader::Hotkeys.reset
    ExecutorModule::COMMANDS_HISTORY.clear
    ModLoader::ModMenu.section['debug.console'] = true
    @scene = Scene_Base.new
    SceneManager.scene = @scene
    ModLoader.held = ModLoader.triggered = []
    Graphics.frame_count += 1
  end

  def teardown
    @scene.terminate
    ModLoader::Hotkeys.reset
    ModLoader::ModMenu.section['debug.console'] = false
  end

  def tick(*keys)
    Graphics.frame_count += 1
    ModLoader.held = ModLoader.triggered = keys
    character = proc { |key| key == K::A ? (@typed_character || '') : '' }
    ModLoader::TextInput.stub(:character, character) { @scene.update_basic }
  ensure
    @typed_character = nil
  end

  def window; @scene.instance_variable_get(:@executor_window); end
  def text; window.input.text; end

  def type(value)
    value.each_char { |char| @typed_character = char; tick(K::A) }
  end

  def test_console_menu_toggle_controls_hotkey_and_reads_saved_value
    ModLoader::ModMenu.section.delete('debug.console')
    refute ExecutorModule.enabled?
    tick(K::F9)
    assert_nil window
    toggle = ModLoader::ModMenu.items_for('Debug').find { |entry| entry.identifier == :console_enabled }
    toggle.value = true
    assert ExecutorModule.enabled?
    tick
    tick(K::F9)
    assert window.active
    tick
    tick(K::F9)
    tick
    toggle.value = false
    tick(K::F9)
    refute window.active
    refute ExecutorModule.enabled?
    assert_equal false, ModLoader::ModMenu.section['debug.console']
  end

  def test_first_open_captures_input_and_accepts_text_without_game_input_leaking
    tick(K::F9)
    assert window.active
    assert_equal :console, C.owner
    type('я😀')
    assert_equal 'я😀', text
    refute Input.trigger?(:C)
    refute Input.press?(:C)
    assert_equal 0, Input.dir4
    tick(K::F9)
    refute window.active
    assert C.blocked?
    tick
    refute C.blocked?
    tick(K::F9)
    assert window.active
    assert_equal :console, C.owner
    assert_equal 'я😀', text
  end

  def test_other_modal_owner_prevents_even_programmatic_console_creation
    C.acquire(:chat)
    @scene.toggle_executor_window
    assert_nil window
    assert_equal :chat, C.owner
  end

  def test_cursor_edits_unicode_in_place_and_home_end_keep_history_on_up_down
    tick(K::F9)
    type('aя😀b')
    tick(K::LEFT)
    tick(K::BACK)
    assert_equal 'aяb', text
    tick(K::HOME)
    tick(K::DELETE)
    assert_equal 'яb', text
    type('W')
    assert_equal 'Wяb', text
    tick(K::RIGHT)
    type('i')
    assert_equal 'Wяib', text
    tick(K::END)
    type('z')
    assert_equal 'Wяibz', text
    ExecutorModule::COMMANDS_HISTORY << ExecutedCommand.new('Command', 'older', 'ok')
    tick(K::UP)
    assert_equal 'older', text
    tick(K::LEFT)
    type('!')
    assert_equal 'olde!r', text
    assert_equal 'older', ExecutorModule::COMMANDS_HISTORY.last.command
    tick(K::DOWN)
    assert_equal '', text
  end

  def test_long_input_scrolls_to_cursor_and_executes_the_complete_command
    tick(K::F9)
    command = "'" + 'Wiя😀' * 40 + "'"
    type(command)
    assert_equal command, text
    assert_input_fits
    assert window.contents.draws.any? { |_, value, _| value.end_with?("'") && value.include?('😀') }
    tick(K::HOME)
    assert_input_fits
    assert window.contents.draws.any? { |_, value, _| value.start_with?("'Wiя😀") }
    tick(K::END)
    assert_input_fits
    tick(K::RETURN)
    assert_equal command, ExecutorModule::COMMANDS_HISTORY.last.command
    refute ExecutorModule::COMMANDS_HISTORY.last.is_error?
    assert_equal '', text
  end

  def test_history_and_input_stay_inside_contents_with_a_visible_caret
    6.times { |i| ExecutorModule::COMMANDS_HISTORY << ExecutedCommand.new('Command', 'W' * 200, i.to_s) }
    tick(K::F9)
    assert_input_fits
    window.contents.draws.each do |rect, _, _|
      assert_operator rect.x + rect.width, :<=, window.contents.width
      assert_operator rect.y + rect.height, :<=, window.contents.height
    end
  end

  def test_deleting_long_input_reveals_the_prefix_and_caret_stops_at_both_ends
    tick(K::F9)
    type('W' * 70)
    assert_operator window.contents.draws.last[1].length, :<, text.length
    60.times { tick(K::BACK) }
    assert_equal 'W' * 10, text
    assert_equal text, window.contents.draws.last[1]
    assert_input_fits
    tick(K::HOME)
    tick(K::LEFT)
    tick(K::BACK)
    assert_equal 0, window.input.cursor
    assert_equal 'W' * 10, text
    tick(K::END)
    tick(K::RIGHT)
    tick(K::DELETE)
    assert_equal text.length, window.input.cursor
    assert_equal 'W' * 10, text
  end

  def test_clipboard_copies_full_command_and_inserts_at_cursor_without_execution
    tick(K::F9)
    type('abc')
    tick(K::LEFT)
    copied = []
    ModLoader::Clipboard.stub(:write, proc { |value| copied << value.dup }) { tick(K::CTRL, K::C) }
    assert_equal ['abc'], copied
    assert_equal 'abc', text
    ModLoader::Clipboard.stub(:read, "я😀\r\nz\t") { tick(K::CTRL, K::V, K::RETURN) }
    assert_equal 'abя😀 z c', text
    assert_empty ExecutorModule::COMMANDS_HISTORY
    type('!')
    assert_equal 'abя😀 z !c', text
    assert_input_fits
    ModLoader::Clipboard.stub(:read, nil) { tick(K::CTRL, K::V) }
    assert_equal 'abя😀 z !c', text
  end

  def assert_input_fits
    # Input is drawn on the final history row. Its rectangles must fit without
    # relying on RGSS's text compression, and the caret remains inside contents.
    y = window.contents.draws.last.first.y
    window.contents.draws.select { |rect, _, _| rect.y == y }.each do |rect, value, _|
      assert_operator window.text_size(value).width, :<=, rect.width
      assert_operator rect.x + rect.width, :<=, window.contents.width
    end
    caret = window.contents.fills.last
    refute_nil caret
    x, caret_y, width, height = caret
    assert_operator x, :>=, 0
    assert_operator x + width, :<=, window.contents.width
    assert_operator caret_y + height, :<=, window.contents.height
  end
end
