# Shared modal input ownership and hotkeys. Raw ModLoader input stays available
# to the owner; RPG Maker Input is muted until the closing keys are released.
$imported ||= {}
unless $imported["IDL-ModLoaderInput"]
$imported["IDL-ModLoaderInput"] = "1.0"

module ModLoader
  module InputCapture
    class << self
      attr_reader :owner

      def acquire(owner)
        raise ArgumentError, "owner required" unless owner
        return true if @owner == owner
        return false if blocked?
        @owner = owner
        true
      end

      def release(owner)
        return false unless @owner == owner
        @owner = nil
        @released_frame = Graphics.frame_count
        true
      end

      def blocked?
        return true if @owner
        return false unless @released_frame
        return true if @released_frame == Graphics.frame_count
        return true if (8..0xFE).any? { |key| ModLoader.input_press?(key) }
        @released_frame = nil
        false
      end

      # Called on RGSS restart, even when F12 skipped scene/window disposal.
      def reset
        @owner = @released_frame = nil
      end
    end
  end

  module Hotkeys
    @actions = {}
    @reset_handlers = {}
    class << self
      # key may be a proc for a remappable key. capture grants access while that
      # owner is active; acquiring/releasing still belongs to the window itself.
      # First registered action wins a collision; current owner takes precedence.
      def register(id, options = {}, &action)
        raise ArgumentError, "key and action required" unless options[:key] && action
        @actions[id] = options.merge(:action => action)
      end

      def unregister(id); @actions.delete(id); end
      def on_reset(id, &handler); @reset_handlers[id] = handler; end

      def reset
        InputCapture.reset
        @frame = nil
        @reset_handlers.each_value { |handler| handler.call }
        InputCapture.reset
      end

      def update(scene)
        return if @frame == Graphics.frame_count
        @frame = Graphics.frame_count
        used = {}
        actions = @actions.values.sort_by { |a| a[:capture] && a[:capture] == InputCapture.owner ? 0 : 1 }
        actions.each do |entry|
          break unless SceneManager.scene.equal?(scene)
          next if InputCapture.blocked? && (!entry[:capture] || entry[:capture] != InputCapture.owner)
          next if entry[:enabled] && !entry[:enabled].call
          key = entry[:key].is_a?(Proc) ? entry[:key].call : entry[:key]
          next if used[key] || !ModLoader.input_trigger?(key)
          used[key] = true
          entry[:action].call(scene)
        end
      end
    end
  end
end

module Input
  class << self
    alias modloader_capture_trigger? trigger?
    alias modloader_capture_press? press?
    alias modloader_capture_repeat? repeat?
    alias modloader_capture_dir4 dir4
    alias modloader_capture_dir8 dir8
  end
  def self.trigger?(key); ModLoader::InputCapture.blocked? ? false : modloader_capture_trigger?(key); end
  def self.press?(key); ModLoader::InputCapture.blocked? ? false : modloader_capture_press?(key); end
  def self.repeat?(key); ModLoader::InputCapture.blocked? ? false : modloader_capture_repeat?(key); end
  def self.dir4; ModLoader::InputCapture.blocked? ? 0 : modloader_capture_dir4; end
  def self.dir8; ModLoader::InputCapture.blocked? ? 0 : modloader_capture_dir8; end
end

class Scene_Base
  alias modloader_hotkeys_update_basic update_basic
  def update_basic
    modloader_hotkeys_update_basic
    ModLoader::Hotkeys.update(self)
  end
end

module SceneManager
  class << self
    alias modloader_input_run run
    def run
      ModLoader::Hotkeys.reset
      modloader_input_run
    end
  end
end
end
