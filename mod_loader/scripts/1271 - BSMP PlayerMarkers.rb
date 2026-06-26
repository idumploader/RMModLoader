#==============================================================================
# BSMP Player Markers — GAME-SPECIFIC co-op QoL. For every peer ON THE SAME MAP, a
# marker: on-screen, a "▼" above their head; off-screen, a directional arrow at the screen
# edge + nickname (so you can find a teammate who wandered off). The local player isn't marked.
#
# One small Sprite PER peer. Each frame we only REPOSITION it (set x/y) — its little bitmap
# is redrawn (the slow CPU draw_text) ONLY when its content actually changes: an on/off-screen
# flip, the arrow direction, or a rename. No full-screen bitmap, no per-frame text work.
# Tied to the map spriteset's lifecycle (disposed with it on a scene change).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-PlayerMarkers"]
$imported["IDL-BSMP-PlayerMarkers"] = "1.0"

if defined?(BSMP)

module BSMP
  module PlayerMarkers
    Z      = 200
    MARGIN = 28     # edge inset for an off-screen arrow
    HEAD   = 40     # px above the feet (screen_y) for the on-screen marker
    W      = 168    # marker bitmap size (name row + glyph row)
    H      = 44

    # One peer's marker: a small sprite we move; its bitmap is redrawn only on a content change.
    class Marker
      def initialize
        @sprite = Sprite.new
        @sprite.bitmap = Bitmap.new(W, H)
        @sprite.bitmap.font.size = 18
        @sprite.ox = W / 2          # center anchor: x/y = the target point
        @sprite.oy = H / 2
        @sprite.z  = Z
        @sprite.visible = false
        @glyph = nil
        @text  = nil
      end

      # Position (and, only if needed, re-render) this marker for peer pl on a (w x h) screen.
      def place(pl, w, h)
        sx = pl.screen_x
        sy = pl.screen_y
        if sx >= 0 and sx <= w and sy >= 0 and sy <= h
          glyph  = "▼"
          text   = ""                      # on-screen: ▼ only (the sprite already shows the nick)
          px, py = sx, sy - HEAD
        else
          cx = [[sx, MARGIN].max, w - MARGIN].min
          cy = [[sy, MARGIN].max, h - MARGIN].min
          glyph  = PlayerMarkers.arrow_glyph(sx - cx, sy - cy)
          text   = pl.nickname.to_s        # off-screen: arrow + nick (no sprite there)
          px, py = cx, cy
        end
        render(glyph, text) if glyph != @glyph or text != @text   # only on a real change
        @sprite.x = px
        @sprite.y = py
        @sprite.visible = true
      end

      def hide;    @sprite.visible = false; end
      def visible?; @sprite.visible; end

      def dispose
        @sprite.bitmap.dispose if @sprite.bitmap and not @sprite.bitmap.disposed?
        @sprite.dispose unless @sprite.disposed?
      end

      def render(glyph, text)
        @glyph = glyph
        @text  = text
        b = @sprite.bitmap
        b.clear
        unless text.empty?
          b.font.color = Color.new(255, 255, 255)
          b.draw_text(0, 0, W, 20, text, 1)
        end
        b.font.color = Color.new(120, 220, 255)
        b.draw_text(0, 20, W, 22, glyph, 1)
      end
    end

    class << self
      def update
        unless active?
          dispose_all
          return
        end
        @markers ||= {}
        w   = Graphics.width
        h   = Graphics.height
        mid = $game_map.map_id
        seen = {}
        $bsmp_players.bsmp_players.each_value do |pl|
          next unless pl.map_id == mid
          id = pl.player_id
          seen[id] = true
          (@markers[id] ||= Marker.new).place(pl, w, h)
        end
        # Drop markers for peers no longer on this map / in the session.
        (@markers.keys - seen.keys).each do |id|
          @markers[id].dispose
          @markers.delete(id)
        end
      end

      def active?
        bsmp_network_running? and $game_map and $bsmp_players and $bsmp_players.size > 0 and
          SceneManager.scene.is_a?(Scene_Map)
      end

      def dispose_all
        return unless @markers
        @markers.each_value { |m| m.dispose }
        @markers = nil
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
# ■ Spriteset_Map — drive + own the markers (auto-disposed on scene change)
#==============================================================================
class Spriteset_Map
  alias bsmp_markers_update update
  def update
    bsmp_markers_update
    BSMP::PlayerMarkers.update
  end

  alias bsmp_markers_dispose dispose
  def dispose
    BSMP::PlayerMarkers.dispose_all
    bsmp_markers_dispose
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-PlayerMarkers"]
