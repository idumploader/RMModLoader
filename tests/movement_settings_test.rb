require_relative 'support/modmenu_rgss'

class Scene_Map < Scene_Base; end
module ModLoader
  class << self
    attr_accessor :movement_mode, :custom_controls
    def controls_change_enabled; !!custom_controls; end
    def movement_keys(mode); self.movement_mode = mode; end
  end
end
module Input
  def self.update; ModLoader.movement_mode; end
end
load File.expand_path('../mod_loader/framework/input/movement.rb', __dir__)

class MovementSettingsTest < Minitest::Test
  def setup
    ModLoader::ModMenu.section.clear
    ModLoader.custom_controls = true
    SceneManager.scene = Scene_Map.new
  end

  def test_unsaved_settings_preserve_original_controls
    assert_equal 2, Input.update
    ModLoader.custom_controls = false
    assert_equal 1, Input.update
  end

  def test_independent_menu_toggles_and_restored_values
    items = ModLoader::ModMenu.items_for('General')
    arrows = items.find { |i| i.identifier == 'movement.arrows' }
    wasd = items.find { |i| i.identifier == 'movement.wasd' }
    [[false, false, 0], [true, false, 1], [false, true, 2], [true, true, 3]].each do |a, w, mode|
      arrows.value = a
      wasd.value = w
      assert_equal mode, Input.update
      assert_equal a, ModLoader::ModMenu.section['movement.arrows']
      assert_equal w, ModLoader::ModMenu.section['movement.wasd']
    end
  end

  def test_leaving_map_restores_menu_bindings_before_polling
    ModLoader::ModMenu.section['movement.arrows'] = true
    assert_equal 3, Input.update
    SceneManager.scene = Scene_Base.new
    assert_equal(-1, Input.update)
    SceneManager.scene = nil
    assert_equal(-1, Input.update)
  end

  def test_old_dll_disables_settings_without_breaking_input
    ModLoader.singleton_class.alias_method :saved_movement_keys, :movement_keys
    ModLoader.singleton_class.remove_method :movement_keys
    refute ModLoader::MovementSettings.available?
    item = ModLoader::ModMenu.items_for('General').find { |i| i.identifier == 'movement.arrows' }
    refute item.selectable?
    Input.update
  ensure
    ModLoader.singleton_class.alias_method :movement_keys, :saved_movement_keys
    ModLoader.singleton_class.remove_method :saved_movement_keys
  end
end
