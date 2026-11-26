# Keyboard walking is configured only while polling input for a map scene.
# Menu/text input bindings and the engine's gamepad input remain unchanged.
$imported ||= {}
unless $imported['ModLoader-MovementSettings']
  $imported['ModLoader-MovementSettings'] = true

  module ModLoader
    module MovementSettings
      def self.available?; ModLoader.respond_to?(:movement_keys); end
      def self.enabled?(key)
        values = ModMenu.section
        return values[key] == true if values.key?(key)
        custom = ModLoader.controls_change_enabled
        key == 'movement.arrows' ? !custom : !!custom
      end

      def self.apply
        return unless available?
        mode = -1
        if defined?(Scene_Map) && SceneManager.scene.is_a?(Scene_Map)
          mode = (enabled?('movement.arrows') ? 1 : 0) |
                 (enabled?('movement.wasd') ? 2 : 0)
        end
        ModLoader.movement_keys(mode)
      end
    end

    ModMenu.category(ModMenu::DEFAULT_CATEGORY, :id => :movement_settings) do |menu|
      menu.header('Movement')
      [['Arrow keys', 'movement.arrows'], ['WASD keys', 'movement.wasd']].each do |label, key|
        menu.toggle(label, :id => key, :key => key,
          :default => MovementSettings.enabled?(key),
          :enabled => proc { MovementSettings.available? },
          :description => 'Walk on the map with these keys. Both options can be enabled together. Menu controls are unchanged. Applies immediately and is saved.')
      end
    end
  end

  module Input
    class << self
      alias movement_settings_original_update update
      def update
        ModLoader::MovementSettings.apply
        movement_settings_original_update
      end
    end
  end
end
