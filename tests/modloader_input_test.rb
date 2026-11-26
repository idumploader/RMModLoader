require_relative 'support/modmenu_rgss'
module ModLoader
  def self.version; '2.5'; end
end
module ModLoader::Keyboard
  F9 = 120
  F5 = 116
end
class Window_Selectable < Window_Base; end
class Scene_MenuBase < Scene_Base; end
class Game_Temp; end
load File.expand_path('../mod_loader/framework/input/line_input.rb', __dir__)
load File.expand_path('../mod_loader/framework/console/executor_scene.rb', __dir__)
load File.expand_path('../mod_loader/framework/console/default_commands.rb', __dir__)
class RGSSReset < Exception; end

class ModLoaderInputTest < Minitest::Test
  C = ModLoader::InputCapture
  H = ModLoader::Hotkeys
  def setup
    H.reset
    @actions = H.instance_variable_get(:@actions).dup
    Graphics.frame_count += 1
    ModLoader.held = ModLoader.triggered = []
    @scene = Scene_Base.new
    SceneManager.scene = @scene
  end
  def teardown
    H.instance_variable_set(:@actions, @actions)
    ModLoader.held = ModLoader.triggered = []
    C.reset
  end
  def tick(*keys)
    Graphics.frame_count += 1
    ModLoader.held = ModLoader.triggered = keys
    @scene.update_basic # Battle waits call this without Scene_Base#update.
  end
  def test_exclusive_owner_and_release_guard
    assert C.acquire(:chat)
    refute C.acquire(:console)
    refute C.release(:console)
    assert_equal :chat, C.owner
    refute Input.trigger?(:C)
    refute Input.press?(:C)
    refute Input.repeat?(:C)
    assert_equal 0, Input.dir4
    assert_equal 0, Input.dir8
    assert C.release(:chat)
    assert C.blocked?
    tick(65)
    assert C.blocked?
    tick
    refute C.blocked?
    assert Input.trigger?(:C)
  end
  def test_owner_hotkey_wins_collision_and_runs_once_in_battle_wait
    calls = []
    H.register(:other, :key => 65) { calls << :other }
    H.register(:test_console, :key => 65, :capture => :console) do
      calls << :console
      C.release(:console)
    end
    C.acquire(:console)
    tick(65)
    H.update(@scene)
    assert_equal [:console], calls
    assert_nil C.owner
    assert C.blocked?
  end
  def test_capture_acquired_by_first_action_blocks_other_actions
    calls = []
    H.register(:first, :key => 65) { C.acquire(:chat); calls << :first }
    H.register(:second, :key => 66) { calls << :second }
    tick(65, 66)
    assert_equal [:first], calls
  end
  def test_persisted_command_binding_uses_dispatcher_and_unbind
    $input_test_count = 0
    ExecutorEnvironment.bind(:F5, '$input_test_count += 1')
    assert_equal '$input_test_count += 1', ExecutorEnvironment.bind(:F5)
    tick(ModLoader::Keyboard::F5)
    assert_equal 1, $input_test_count
    C.acquire(:chat)
    tick(ModLoader::Keyboard::F5)
    assert_equal 1, $input_test_count
    C.reset
    ExecutorEnvironment.unbind(:F5)
    tick(ModLoader::Keyboard::F5)
    assert_equal 1, $input_test_count
  end
  def test_reset_clears_capture_when_disposal_was_skipped
    C.acquire(:console)
    SceneManager.run
    assert_nil C.owner
    refute C.blocked?
  end
  def test_real_console_toggle_releases_during_battle_wait
    window = Executor_Window.allocate
    window.instance_variable_set(:@active, true)
    window.define_singleton_method(:close) { @closed = true }
    window.define_singleton_method(:closed?) { @closed }
    window.define_singleton_method(:update) {}
    @scene.instance_variable_set(:@executor_window, window)
    C.acquire(:console)
    ModLoader::ModMenu.section['debug.console'] = true
    tick(ModLoader::Keyboard::F9)
    assert window.closed?
    refute window.active
    assert_nil C.owner
  ensure
    ModLoader::ModMenu.section['debug.console'] = false
  end
  def test_console_reports_syntax_errors_but_propagates_rgss_reset
    window = Executor_Window.allocate
    window.define_singleton_method(:max_command_count) { 30 }
    window.instance_variable_set(:@input, ModLoader::TextInput::Line.new)
    window.input.replace('(')
    window.execute_symbols
    assert ExecutorModule::COMMANDS_HISTORY.last.is_error?
    window.input.replace('raise RGSSReset')
    assert_raises(RGSSReset) { window.execute_symbols }
    window.instance_variable_set(:@active, true)
    window.define_singleton_method(:check_new_symbols) { raise RGSSReset }
    window.instance_variable_set(:@updates, 0)
    assert_raises(RGSSReset) { window.update }
  end
end
