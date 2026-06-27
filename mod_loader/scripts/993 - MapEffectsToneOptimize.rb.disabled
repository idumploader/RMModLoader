#==============================================================================
# MapEffectsToneOptimize — make a pure screen TONE/COLOR cheap under Zeus "Map Effects" (240).
#
# Zeus Map Effects applies any active effect by SNAPSHOTTING the whole map (Graphics.snap_to_
# bitmap — a full framebuffer GPU->CPU readback) every couple of frames and re-displaying it
# with the effect. That snapshot is what stutters the game while ANY non-zero tone is set
# (e.g. the co-op beacon's gray=180 desaturation) — even gray=1 triggers the whole pipeline.
#
# A pure tone/color needs no snapshot: the native Viewport#tone= / #color= apply it on the
# GPU for free. This overrides the effects update so that when the ONLY active effect is a
# tone and/or color (no zoom / blur / wave / pixelize / angle / hue / mirror / blend), it
# tones the map viewport natively and skips the snapshot path entirely. Real geometric
# effects (the beacon's brief activation blur, zoom, etc.) still go through the snapshot.
#
# Standalone deploy patch. Loads after the game's script 240 (every mod script does).
#==============================================================================

$imported ||= {}
if not $imported["IDL-MapEffectsToneOptimize"]
$imported["IDL-MapEffectsToneOptimize"] = "1.0"

if defined?(Game_Map_Effects)
  class Game_Map_Effects
    # Active because of ONLY a tone and/or color (nothing that needs the snapshot pipeline).
    # Checks the live values, so it stays true throughout a tone fade (set_tone with a
    # duration) — the native tone animates right along with @tone.
    def tone_only?
      return false unless @active
      return false if blur? or @mirror or @blend_type != 0
      return false if @zoom_x != 1 or @zoom_y != 1 or @pixelize > 1
      return false if @angle % 360 != 0 or @hue.to_i % 360 != 0
      return false if @wave_amp * @zoom_x >= 1 and @wave_length * @zoom_y >= 1
      @tone.red != 0 or @tone.green != 0 or @tone.blue != 0 or @tone.gray != 0 or @color.alpha != 0
    end
  end
end

if defined?(Spriteset_Map_Effects)
  class Spriteset_Map_Effects
    alias bsmp_tone_orig_update update
    def update(tilemap_oy = 0)
      if @data.tone_only?
        enter_native_tone
        @map_viewports.each { |vp| vp.tone = @data.tone; vp.color = @data.color }
      else
        exit_native_tone if @native_toned
        bsmp_tone_orig_update(tilemap_oy)
      end
    end

    # Tear down the snapshot pipeline (dispose(false) hides the effects viewport, frees its
    # snapshot sprites/bitmaps and re-shows the real map viewports) — once, on entry.
    def enter_native_tone
      return if @native_toned
      dispose(false) if @viewport.visible
      @native_toned = true
    end

    # Leaving native mode (a real effect arrived, or everything cleared): reset the map
    # viewport's native tone/color so the snapshot path / neutral map isn't double-toned.
    def exit_native_tone
      @map_viewports.each { |vp| vp.tone = Tone.new(0, 0, 0, 0); vp.color = Color.new(0, 0, 0, 0) }
      @native_toned = false
    end
  end
end

end # not $imported["IDL-MapEffectsToneOptimize"]
