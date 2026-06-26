#==============================================================================
# BSMP Player Markers — GAME-SPECIFIC co-op QoL. For every peer ON THE SAME MAP, draw
# a marker: on-screen, a "▼" + nickname floating above their head; off-screen, a
# directional arrow at the screen edge pointing toward them + nickname (so you can find a
# teammate who wandered off). The local player isn't marked.
#
# Render: a single screen-space Sprite + Bitmap (peers' positions come from their
# Game_Character screen_x/screen_y, already map-scroll-adjusted), redrawn each frame and
# tied to the map spriteset's lifecycle (created lazily, disposed with the spriteset on a
# scene change). Loads after the player-sprite layer (1220/1230/1240).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-PlayerMarkers"]
$imported["IDL-BSMP-PlayerMarkers"] = "1.0"

if defined?(BSMP)

module BSMP
  module PlayerMarkers
    Z      = 200    # above map characters, below message windows
    MARGIN = 28     # edge inset for an off-screen arrow
    HEAD   = 40     # px above the feet (screen_y) for the on-screen marker

    class << self
      def update
        unless active?
          dispose_sprite
          return
        end
        ensure_sprite
        draw
      end

      def active?
        bsmp_network_running? and $game_map and $bsmp_players and $bsmp_players.size > 0 and
          SceneManager.scene.is_a?(Scene_Map)
      end

      def ensure_sprite
        return if @sprite and not @sprite.disposed?
        @sprite = Sprite.new
        @sprite.bitmap = Bitmap.new(Graphics.width, Graphics.height)
        @sprite.z = Z
        @sprite.bitmap.font.size = 18
      end

      def dispose_sprite
        return unless @sprite
        @sprite.bitmap.dispose if @sprite.bitmap and not @sprite.bitmap.disposed?
        @sprite.dispose unless @sprite.disposed?
        @sprite = nil
      end

      def draw
        b = @sprite.bitmap
        b.clear
        w = Graphics.width
        h = Graphics.height
        mid = $game_map.map_id
        $bsmp_players.bsmp_players.each_value do |pl|
          next unless pl.map_id == mid   # same map only
          sx = pl.screen_x
          sy = pl.screen_y
          name = pl.nickname.to_s
          if sx >= 0 and sx <= w and sy >= 0 and sy <= h
            draw_glyph(b, sx, sy - HEAD, "▼")              # on-screen: ▼ only — the sprite already shows the nick
          else
            cx = [[sx, MARGIN].max, w - MARGIN].min        # clamp to the edge nearest them
            cy = [[sy, MARGIN].max, h - MARGIN].min
            draw_marker(b, cx, cy, arrow_glyph(sx - cx, sy - cy), name)  # off-screen: arrow + nick (no sprite there)
          end
        end
      end

      # Glyph only (cyan), centered on (x, y).
      def draw_glyph(b, x, y, glyph)
        b.font.color = Color.new(120, 220, 255)
        b.draw_text(x - 40, y - 4, 80, 22, glyph, 1)
      end

      # Nickname (white) above + glyph below, centered on (x, y). For the off-screen arrow,
      # where the peer's own sprite/nick isn't visible.
      def draw_marker(b, x, y, glyph, name)
        unless name.empty?
          b.font.color = Color.new(255, 255, 255)
          b.draw_text(x - 80, y - 20, 160, 18, name, 1)
        end
        draw_glyph(b, x, y, glyph)
      end

      # One of the 8 arrow glyphs by dominant direction of (dx, dy).
      def arrow_glyph(dx, dy)
        ax = dx.abs
        ay = dy.abs
        if ax > ay * 2
          dx > 0 ? "→" : "←"
        elsif ay > ax * 2
          dy > 0 ? "↓" : "↑"
        elsif dx > 0
          dy > 0 ? "↘" : "↗"
        else
          dy > 0 ? "↙" : "↖"
        end
      end
    end
  end
end

#==============================================================================
# ■ Spriteset_Map — drive + own the marker overlay (auto-disposed on scene change)
#==============================================================================
class Spriteset_Map
  alias bsmp_markers_update update
  def update
    bsmp_markers_update
    BSMP::PlayerMarkers.update
  end

  alias bsmp_markers_dispose dispose
  def dispose
    BSMP::PlayerMarkers.dispose_sprite
    bsmp_markers_dispose
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-PlayerMarkers"]
