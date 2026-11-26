# Apply only between scenes, after all old render objects have been disposed.
$imported ||= {}
unless $imported['IDL-DisplayLiveResize']
$imported['IDL-DisplayLiveResize'] = '1.0'
if defined?(ModLoader::Display)
module ModLoader::Display
  class << self
    def cancel_live_resize
      @live_resolution = @live_map_size = @resize_request = nil
    end

    def schedule_live_resize(scene)
      return unless (@live_resolution || @live_map_size) && !@resize_request && live_resize_scene?
      return if ModLoader::ModMenu.active? || !SceneManager.scene.equal?(scene)
      size = resolution.split('x').map { |v| v.to_i }
      original_map = map_size == :original
      @live_resolution = @live_map_size = nil
      return if size == [Graphics.width, Graphics.height] && original_map == ModLoader.hrfix_settings(false)[2]
      mode = renderer_mode
      return report_renderer_change(false) if renderer_available? && !ModLoader.parallel_renderer_frame_mode(0)
      @resize_request = [size, mode, original_map]
      SceneManager.goto(scene.class)
    end

    def apply_live_resize
      return unless @resize_request
      size, mode = @resize_request
      old_size = [Graphics.width, Graphics.height]
      old_original = ModLoader.hrfix_settings(false)[2]
      original_map = @resize_request[2]
      # A frozen transition surface still has the previous dimensions. Release
      # it while the native transition patches still describe the old screen.
      Graphics.transition(0)
      map_applied = original_map == old_original || (live_map_size_available? && ModLoader.apply_hrfix_map_size(original_map))
      unless map_applied && ModLoader.apply_hrfix_resolution(*size) && [Graphics.width, Graphics.height] == size
        @resize_request[0] = old_size
        ModLoader.apply_hrfix_map_size(old_original) if live_map_size_available?
        ModLoader.apply_hrfix_resolution(*old_size)
        report_renderer_change(false)
        return
      end
      HRFix::MapSize.refresh if defined?(HRFix::MapSize)
      if defined?(GraphicsReplace)
        GraphicsReplace::RESIZE_MAPPING.each do |path, dimensions|
          if path.start_with?('Graphics/Parallaxes/')
            old_map = old_original ? [640, 480] : old_size
            new_map = original_map ? [640, 480] : size
            dimensions[0] = (dimensions[0] * new_map[0].to_f / old_map[0]).round
            dimensions[1] = (dimensions[1] * new_map[1].to_f / old_map[1]).round
            next
          end
          dimensions[0] = (dimensions[0] * size[0].to_f / old_size[0]).round
          dimensions[1] = if path == 'Graphics/System/noise_line'
            size[1] + 100
          else
            (dimensions[1] * size[1].to_f / old_size[1]).round
          end
          dimensions[0] = 1 if path == 'Graphics/System/noise_line'
        end
      end
      Cache.clear
      BSHudBitmapCache.clear if defined?(BSHudBitmapCache)
      if SceneManager.scene.is_a?(Scene_Map) && $game_map && $game_map.map_id > 0 && $game_player
        $game_player.center($game_player.x, $game_player.y)
      end
      report_save(ModLoader.save_hrfix_settings(size[0], size[1], @resize_request[2]))
    end

    def finish_live_resize
      return unless @resize_request
      mode = @resize_request[1]
      @resize_request = nil
      report_renderer_change(change_renderer(mode, false)) if mode != 0
    end
  end
end

class Scene_Base
  alias display_resize_update_basic update_basic
  alias display_resize_start start
  alias display_resize_post_start post_start
  def update_basic
    display_resize_update_basic
    ModLoader::Display.schedule_live_resize(self)
  end
  def start
    ModLoader::Display.apply_live_resize
    display_resize_start
  end
  def post_start
    display_resize_post_start
    ModLoader::Display.finish_live_resize
  end
end
end
end
