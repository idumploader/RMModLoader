#==============================================================================
# ViewportEffects - Ruby front-end for the native viewport zoom.
#
# The heavy lifting is in C++ (ViewportEffectsHooks): the scene walker captures
# a viewport's subtree into a backbuffer and stretch-blits it back, zoomed about
# a focus point.
#
# TWO ways to drive it:
#
#   * Per-viewport (general) - methods defined natively on ANY Viewport:
#       vp.zoom = 1.5            # 1.0 = off; >1 zooms in (Float or Int)
#       vp.zoom                  # => current factor
#       vp.zoom_center(x, y)     # pin the focus to a screen pixel
#       vp.zoom_auto_center      # back to the viewport's centre
#
#   * Map default (convenience) - this namespace drives the auto-detected map
#     viewport, so you don't have to fish it out of the spriteset:
#       ModLoader::Viewport.enabled = true
#       ModLoader::Viewport.zoom    = 1.5
#       ModLoader::Viewport.focus_player   # centre on the player (follow-cam)
#       ModLoader::Viewport.auto_center
#
# The C++ side only registers any of this when "viewport_effects" is true in
# mod_loader.json, so every wrapper degrades to a no-op (returning nil / false)
# when the feature is disabled - callers never need to guard themselves.
#==============================================================================

$imported ||= {}
if not $imported["IDL-ViewportEffects"]
$imported["IDL-ViewportEffects"] = "1.0"

module ModLoader
  module Viewport
    class << self
      # @return [Boolean] whether the native hook + Ruby API are present this run
      def available?
        ModLoader.respond_to?(:viewport_zoom=)
      end

      # The current map's main viewport (Spriteset_Map @viewport1 - holds the
      # tilemap + characters; the one C++ auto-detects). nil off the map. Use it
      # with the per-viewport methods directly, e.g.:
      #   ModLoader::Viewport.map.zoom = 2.0
      #   ModLoader::Viewport.map.zoom_center(px, py)
      def map
        scene = SceneManager.scene
        return nil unless scene.is_a?(Scene_Map)
        spriteset = scene.instance_variable_get(:@spriteset)
        spriteset && spriteset.instance_variable_get(:@viewport1)
      end

      # Enable/disable the capture+blit at runtime (no-op if feature off in config).
      def enabled=(value)
        ModLoader.viewport_effects = value if available?
        value
      end

      def enabled?
        ModLoader.respond_to?(:viewport_effects?) && ModLoader.viewport_effects?
      end

      # Zoom factor. 1.0 disables the stretch; values >1 zoom in. Clamped to >=1
      # on the C++ side (sampling can't zoom out). Accepts Integer or Float.
      def zoom=(factor)
        ModLoader.viewport_zoom = factor if available?
        factor
      end

      # Pin the zoom focus to a screen-pixel point (viewport-local; the map
      # viewport is full-screen so screen coords == viewport coords).
      def center(x, y)
        ModLoader.viewport_set_center(x, y) if available?
        nil
      end

      # Back to centre-of-viewport zoom.
      def auto_center
        ModLoader.viewport_auto_center if available?
        nil
      end

      # Convenience: centre the zoom on the player's on-screen position. Pass a
      # +factor+ to set the zoom in the same call. Safe to call every frame.
      def focus_player(factor = nil)
        return unless available?
        ModLoader.viewport_zoom = factor if factor
        if $game_player
          ModLoader.viewport_set_center($game_player.screen_x, $game_player.screen_y)
        end
        nil
      end

      # Demo "dream" effect on the map viewport: a soft blur plus a touch of
      # zoom. Just type `ModLoader::Viewport.dream` in the console; pass false
      # (or call .clear) to turn it off.
      #   ModLoader::Viewport.dream        # on
      #   ModLoader::Viewport.dream(false) # off
      def dream(on = true)
        return unless available?
        vp = map
        return unless vp
        vp.blur = on ? 5   : 0
        vp.zoom = on ? 1.1 : 1.0
        on
      end

      # Reset every effect on the map viewport back to normal.
      def clear
        return unless available?
        vp = map
        return unless vp
        vp.blur = 0
        vp.zoom = 1.0
        vp.angle = 0
        vp.flip_x = false
        vp.flip_y = false
        vp.wave_off
        vp.zoom_auto_center
        nil
      end
    end
  end
end

end # not $imported["IDL-ViewportEffects"]
