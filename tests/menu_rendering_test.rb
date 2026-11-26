require 'minitest/autorun'
module ModLoader
  class << self
    attr_accessor :accept_blur, :blur_calls
    def menu_bitmap_blur(bitmap)
      self.blur_calls = (blur_calls || 0) + 1
      bitmap.result = :fast if accept_blur
      !!accept_blur
    end
  end
  module Display
    class Settings < Hash
      def commit; end
    end
    def self.settings; @settings ||= Settings.new; end
  end
end
class Bitmap
  attr_accessor :result
  def blur; self.result = :original; nil; end
end
module Graphics
  class << self
    attr_accessor :last_transition
    def transition(*args); self.last_transition = args; end
    def snap_to_bitmap; Bitmap.new; end
  end
end
module SceneManager
  class << self
    attr_accessor :background_bitmap, :fail
    def snapshot_for_background
      raise 'snapshot failed' if fail
      self.background_bitmap = Graphics.snap_to_bitmap
      background_bitmap.blur
    end
  end
end
class Scene_Base
  def pre_terminate; end
  def perform_transition; Graphics.transition(transition_speed); end
  def transition_speed; 10; end
end
class Scene_MenuBase < Scene_Base; end
class Scene_Menu < Scene_MenuBase; end
class Scene_Map < Scene_Base
  attr_accessor :black
  def transition_speed; 15; end
  def perform_transition; black ? Graphics.transition(0) : super; end
end
class Scene_Title < Scene_Base
  def transition_speed; 20; end
end
class Scene_Battle < Scene_Base; end
load File.expand_path('../mod_loader/framework/renderer/menu_rendering.rb', __dir__)
class MenuRenderingTest < Minitest::Test
  def setup
    ModLoader::Display.settings.clear
    ModLoader::MenuRendering.previous_scene_class = nil
    ModLoader.accept_blur = true
    ModLoader.blur_calls = 0
    SceneManager.fail = false
  end
  def test_only_background_blur_is_accelerated
    bitmap = Bitmap.new
    bitmap.blur
    assert_equal :original, bitmap.result
    assert_equal 0, ModLoader.blur_calls
    SceneManager.snapshot_for_background
    assert_equal :fast, SceneManager.background_bitmap.result
    ModLoader::MenuRendering.fast_blur = false
    SceneManager.snapshot_for_background
    assert_equal :original, SceneManager.background_bitmap.result
  end
  def test_native_refusal_falls_back_and_exception_restores_scope
    ModLoader.accept_blur = false
    SceneManager.snapshot_for_background
    assert_equal :original, SceneManager.background_bitmap.result
    SceneManager.fail = true
    assert_raises(RuntimeError) { SceneManager.snapshot_for_background }
    refute ModLoader::MenuRendering.background?
  end
  def test_transition_modes_and_return_to_map
    control = ModLoader::MenuRendering
    Scene_Menu.new.perform_transition
    assert_equal [10], Graphics.last_transition
    control.transition_mode = :fast
    Scene_Menu.new.perform_transition
    assert_equal [5], Graphics.last_transition
    Scene_Menu.new.pre_terminate
    Scene_Map.new.perform_transition
    assert_equal [8], Graphics.last_transition
    Scene_Title.new.perform_transition
    assert_equal [10], Graphics.last_transition
    control.transition_mode = :off
    Scene_Menu.new.perform_transition
    assert_equal [0], Graphics.last_transition
    Scene_Map.new.perform_transition
    assert_equal [0], Graphics.last_transition
  end
  def test_battle_event_mask_and_black_map_are_unchanged
    control = ModLoader::MenuRendering
    control.transition_mode = :off
    Scene_Menu.new.pre_terminate
    Scene_Battle.new.perform_transition
    assert_equal [10], Graphics.last_transition
    Graphics.transition(45, 'BattleStart', 100)
    assert_equal [45, 'BattleStart', 100], Graphics.last_transition
    Graphics.transition(12)
    assert_equal [12], Graphics.last_transition
    control.with_transition { Graphics.transition(45, 'BattleStart', 100) }
    assert_equal [45, 'BattleStart', 100], Graphics.last_transition
    map = Scene_Map.new
    map.black = true
    control.transition_mode = :fast
    map.perform_transition
    assert_equal [0], Graphics.last_transition
  end
  def test_reload_keeps_settings_without_rewrapping_or_old_scene
    control = ModLoader::MenuRendering
    control.fast_blur = false
    control.transition_mode = :fast
    Scene_Menu.new.pre_terminate
    before = Graphics.method(:menu_rendering_original_transition)
    load File.expand_path('../mod_loader/framework/renderer/menu_rendering.rb', __dir__)
    assert_equal before, Graphics.method(:menu_rendering_original_transition)
    assert_nil control.previous_scene_class
    refute control.fast_blur?
    assert_equal :fast, control.transition_mode
    refute control.send(:transition_mode=, :invalid)
    assert_equal :fast, control.transition_mode
  end
end
