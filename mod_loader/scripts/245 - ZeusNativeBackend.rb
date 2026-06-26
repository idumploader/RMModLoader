#==============================================================================
# ZeusNativeBackend - drive Zeus Map Effects through the native ViewportEffects.
#
# Zeus' "Map Effects" (game script 240) splits cleanly into:
#   * Game_Map_Effects ($game_map.effects)  -- DATA + animation (set_zoom/set_wave/
#     set_radial_blur/...), twined over a duration. We KEEP this untouched: it stays
#     the single source of truth and keeps animating (Game_Map#update calls
#     effects.update every frame, an alias we don't touch).
#   * Spriteset_Map_Effects                  -- the RENDERER. Every frame it calls
#     Graphics.snap_elements_to_bitmap (a full-screen software snapshot -> GC churn,
#     the slow part) and spawns blur_division+1 sprite copies. It also HIDES
#     @viewport1 and shows the snapped copy instead. We REPLACE this entirely.
#
# Instead of snapshotting, we let the engine render @viewport1 as usual and the
# native walker hook (ViewportEffectsHooks) captures that viewport's subtree into a
# private backbuffer and transform-blits it (zoom/angle/flip/wave/blur/pixelize) -
# no snap_to_bitmap, no per-frame GC. So @viewport1 must stay VISIBLE, which is why
# we bypass Zeus' renderer rather than just neutering parts of it.
#
# Each frame (on the map) we read $game_map.effects' animated values and push them to
# ModLoader::Viewport.map (== @viewport1). One-way: the effects object holds the truth,
# we only set native fields - no getters needed.
#
# Gated by config "zeus_native_backend": true. Off/absent -> this file no-ops and the
# original Zeus renderer runs unchanged (safe fallback). Also no-ops if the native API
# isn't present or Zeus (Game_Map_Effects) isn't in this game build.
#
# NOT mapped yet (rare; Zeus renderer still gone, so these become inert under the
# native backend - revisit if real content needs them):
#   * linear_blur (directional) - no native equivalent yet
#   * motion_blur (temporal trail) - needs frame accumulation
#   * hue rotation, blend_type, opacity - niche
#==============================================================================

$imported ||= {}
if not $imported["IDL-ZeusNativeBackend"]
$imported["IDL-ZeusNativeBackend"] = "1.0"

module ModLoader
  module ZeusNative
    # --- calibration (Zeus units -> native 0..100 / px). Tune in-game. -------------
    GAUSS_K      = 0.5                    # gaussian_blur_length (px spread) -> box radius
    ZB_K         = 100.0                  # |zoom_blur_length| (~0.5) -> strength 0..100
    RB_K         = 3.0                    # |radial_blur_angle| (deg) -> strength 0..100
    WAVE_SPEED_K = Math::PI / 180.0 / 60.0 # wave_speed (deg/sec) -> rad/frame @60fps

    class << self
      def installed?() @installed end       # the Spriteset_Map override is in place
      def native_on?() @native_on end       # currently using the native backend (vs Zeus)

      # Flip native<->Zeus at runtime (e.g. from the test menu). The actual handover
      # (tear down Zeus' renderer / drop the native transform) happens lazily in
      # Spriteset_Map#update, which owns @map_effects -- here we just set the flag.
      def native_on=(v) @native_on = !!v end

      # Install the override whenever we CAN (native API + Zeus present), regardless of
      # config -- so the runtime toggle always works. config "zeus_native_backend" only
      # sets the STARTUP default; off/absent -> start in Zeus mode (our update branch
      # replicates Zeus' original renderer exactly, so it's identical to no shim).
      def init
        @native_on = ((ModLoader.config_get("zeus_native_backend") rescue nil) == true)
        @installed = (defined?(ModLoader::Viewport) ? ModLoader::Viewport.available? : false) &&
                     !!defined?(Game_Map_Effects)
        @was_active = false
        @installed
      end

      # Per-frame bridge, called from Spriteset_Map#update with the live @viewport1.
      # When Zeus effects are idle we clear ONCE and then leave the viewport alone, so
      # manual `ModLoader::Viewport.map.*` console tinkering still works between effects.
      def bridge(viewport1)
        return unless viewport1
        return unless $game_map && $game_map.respond_to?(:effects)
        eff = $game_map.effects
        if eff.active?
          apply(viewport1, eff)
          @was_active = true
        elsif @was_active
          clear(viewport1)
          @was_active = false
        end
      end

      def apply(vp, eff)
        # zoom (Zeus zoom_x is the visual magnification; Game_Map's scroll-zoom only
        # widens scroll limits to keep the player centred, so no double-counting).
        vp.zoom = eff.zoom_x
        if eff.zoom_x > 1
          vp.zoom_center(eff.x, eff.y)   # Zeus' animated focus (set_origin)
        else
          vp.zoom_auto_center
        end
        vp.angle    = eff.angle % 360
        vp.flip_x   = eff.mirror
        vp.pixelize = (eff.pixelize > 1 ? eff.pixelize.round : 1)

        # blur family (gated by Zeus' blur?: blur_division >= 1).
        blurring = eff.blur?
        vp.blur        = (blurring && eff.gaussian_blur_length != 0) ? clamp((eff.gaussian_blur_length.abs * GAUSS_K).round, 0, 64)  : 0
        vp.zoom_blur   = (blurring && eff.zoom_blur_length   != 0) ? clamp((eff.zoom_blur_length.abs   * ZB_K).round,  0, 100) : 0
        vp.radial_blur = (blurring && eff.radial_blur_angle  != 0) ? clamp((eff.radial_blur_angle.abs  * RB_K).round,  0, 100) : 0

        # wave (Zeus: amp/length px, speed deg/sec; our native advances phase itself).
        if eff.wave_amp != 0 && eff.wave_length >= 1
          vp.wave(eff.wave_amp, eff.wave_length, eff.wave_speed * WAVE_SPEED_K)
        else
          vp.wave_off
        end

        # tone / colour. The engine just set vp.tone to the map's screen tone (in
        # zeus_map_effects_update, right before us). We can't faithfully COMPOSE two
        # tones in one slot: RGSS applies a single tone to the raw pixels (desaturate by
        # gray, then add RGB), so adding a reddish ambient offset onto a gray=255 effect
        # gives "grayscale, then re-tinted red" instead of a neutral grey. Zeus dodges
        # this by baking the screen tone into its snapshot first, then desaturating - two
        # passes we don't have. So:
        #   * neutral effect tone -> leave vp.tone alone (keep the map's ambient tint);
        #   * non-neutral effect tone -> REPLACE (the effect's tone wins, e.g. set_tone
        #     grayscale yields a clean neutral grey, matching Zeus' end result).
        if (t = eff.tone) && (t.red != 0 || t.green != 0 || t.blue != 0 || t.gray != 0)
          vp.tone.set(t.red, t.green, t.blue, t.gray)
        end
        if (c = eff.color) && c.alpha != 0
          vp.color.set(c.red, c.green, c.blue, c.alpha)
        end
      end

      # Reset only the geometric/blur transform. Tone & colour are left to the engine
      # (it owns the map's screen tone; zeroing them here would wipe the ambient tint).
      def clear(vp)
        vp.zoom = 1.0
        vp.angle = 0
        vp.flip_x = false
        vp.flip_y = false
        vp.blur = 0
        vp.zoom_blur = 0
        vp.radial_blur = 0
        vp.pixelize = 1
        vp.wave_off
        vp.zoom_auto_center
      end

      # Hand the viewport back to Zeus' renderer: drop the native transform so the two
      # don't both draw. Tone/colour untouched (engine-owned).
      def deactivate(vp)
        clear(vp) if vp
        @was_active = false
      end

      def clamp(v, lo, hi) v < lo ? lo : (v > hi ? hi : v) end
    end
  end
end

# Install when possible; the per-frame branch picks native vs Zeus by the runtime flag.
if ModLoader::ZeusNative.init
  class Spriteset_Map
    # zeus_map_effects_update / _dispose are the ENGINE-ORIGINAL methods (Zeus aliased
    # them before redefining). We call the engine original, then EITHER run the native
    # bridge OR replicate Zeus' own renderer - switchable live via ZeusNative.native_on.
    # @vfx_zeus_live tracks which path is currently set up, so a toggle hands over
    # cleanly: going native tears down @map_effects (un-hiding @viewport1 for our
    # walker); going Zeus drops the native transform first.
    def update
      zeus_map_effects_update
      if ModLoader::ZeusNative.native_on?
        if @vfx_zeus_live
          if @map_effects then @map_effects.dispose(false); @map_effects = nil end
          @vfx_zeus_live = false
        end
        ModLoader::ZeusNative.bridge(@viewport1)
      else
        unless @vfx_zeus_live
          ModLoader::ZeusNative.deactivate(@viewport1)
          @vfx_zeus_live = true
        end
        @map_effects ||= Spriteset_Map_Effects.new(@viewport1)
        @map_effects.update(@tilemap.oy)
      end
    end

    def dispose
      @map_effects.dispose if @map_effects   # only exists in Zeus mode
      zeus_map_effects_dispose
    end
  end
  ModLoader.log("[ZeusNativeBackend] installed (start=#{ModLoader::ZeusNative.native_on? ? 'native' : 'zeus'})\n") if ModLoader.respond_to?(:log)
end

end # not $imported["IDL-ZeusNativeBackend"]
