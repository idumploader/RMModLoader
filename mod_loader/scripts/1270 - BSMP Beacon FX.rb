#==============================================================================
# BSMP Beacon FX — GAME-SPECIFIC (BLACK SOULS 2). Mirror the time-overlap device's
# (CE54 menu -> CE55 toggle) activation / deactivation ANIMATION onto the other peers.
#
# Why a dedicated script: CE55 mixes the screen FX (blur / flash / tone / fog / noise)
# with state writes we already sync separately — var48 += 1 (a RELATIVE counter) and the
# switch 20 toggle. Mirroring the whole CE (SHARED_COMMON_EVENT_IDS) would double-count
# var48 and race the toggle, so we replay ONLY the visuals, driven off the already-shared
# switch 20. All of this is BS2-specific (map_effects / rich_fog / the exact SE names),
# hence its own file, isolated from the generic sync layer.
#
# Trigger: switch 20 ("时间重叠开启") is in SHARED_SWITCH_IDS, so a toggle on one peer is
# applied on the others through on_switch_changed -> apply_fact (sets $bsmp_applying_fact).
# We alias Game_Switches#[]= (after 1240's broadcast alias): when switch 20 is applied
# FROM THE NETWORK and the value actually flips, we play the matching FX. A LOCAL toggle
# (the peer that used the device, running CE55) has $bsmp_applying_fact = false there — it
# already saw CE55's own FX — so it never double-plays.
#
# Two paths (per the "interpreter busy" question):
#   * map interpreter IDLE  -> variant 2: the exact CE55 visual command list run on
#       $game_map.interpreter, so the player is frozen for the transition exactly like the
#       peer who toggled it (CE55 runs on the same interpreter for them).
#   * map interpreter BUSY  -> variant 1: snap the end state directly (tone/fog/flash, no
#       blur waits), safe to do while another event holds the interpreter.
#
# NOT mirrored (intentional): the var48/switch writes (synced elsewhere), the BGM fadeout
# (CE55 never restores BGM — the map's own autoplay does, which a remote peer doesn't run,
# so fading it could strand them in silence), and the CE57/CE58 time-overlap BUFF (state 47
# is a personal per-actor gameplay effect, not animation; sync it separately if wanted).
#
# Known gap: this fires on the LIVE toggle only. A peer that isn't on the beacon map when
# it flips (or one that joins with switch 20 already on) won't get the persistent fog/tone
# until a fresh toggle — that's the separate "apply persistent map state on entry" problem.
#
# Loads after 1240 (Game_Switches broadcast alias) and 1200 (BSMP / $bsmp_applying_fact).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BeaconFX"]
$imported["IDL-BSMP-BeaconFX"] = "1.0"

if defined?(BSMP)

module BSMP
  module BeaconFX
    SWITCH      = 20      # 时间重叠开启 — shared world flag whose sync drives the FX
    EFFECTS_OFF = 27      # 时间重叠特效关闭 — per-peer "reduce effects" setting (read locally)

    class << self
      # Switch 20 was just applied from the network (a remote peer toggled the device).
      # Mirror the animation. on = the new switch value (true = activating).
      def on_remote_toggle(on)
        return unless bsmp_network_running?
        return unless SceneManager.scene.is_a?(Scene_Map)
        # The time-overlap device can be used on ANY map and its tone/fog applies to
        # wherever the player stands, so mirror on whatever map the receiver is on.
        return if $game_map.nil?
        interp = $game_map.interpreter
        if interp and not interp.running?
          interp.setup(fx_list(on), 0)  # variant 2: full anim, player frozen like the toggler
        else
          snap(on)                       # variant 1: interpreter busy -> snap the end state
        end
      end

      # Re-assert the DURABLE time-overlap state for the current map (no animation, flash,
      # SE or blur). Called on every map entry (walk-transfer, and save-load / world-sync on
      # join). Needed because the persistent fog is normally re-applied by a per-map autorun
      # gated on switch 20, which is SUPPRESSED on a non-owner; and on join the snapshot sets
      # switch 20 before we're on Scene_Map, so on_remote_toggle never fired. Idempotent.
      def apply_persistent
        return unless bsmp_network_running?
        return unless SceneManager.scene.is_a?(Scene_Map)
        return if $game_map.nil?
        if $game_switches[SWITCH]
          fx = ($game_map.effects rescue nil)
          fx.set_tone(0, 0, 0, 180, 1) if fx
          $game_system.rich_fog = true if $game_system.respond_to?(:rich_fog=)
        elsif $game_system.respond_to?(:rich_fog) and $game_system.rich_fog
          # stale fog carried over after the device was switched off elsewhere -> clear it
          $game_system.rich_fog = false
          $game_system.end_noise if $game_system.respond_to?(:end_noise)
        end
      end

      # Variant 1 — apply the end state directly (no blur, no waits), safe while the map
      # interpreter is mid-event. The tone/color still ease over their own 60f duration.
      def snap(on)
        fx = ($game_map.effects rescue nil)
        if on
          fx.set_tone(0, 0, 0, 180, 60) if fx
          $game_system.rich_fog = true if $game_system.respond_to?(:rich_fog=)
        else
          if fx
            fx.set_color(0, 0, 0, 0, 60)
            fx.set_tone(0, 0, 0, 0, 60)
          end
          $game_system.rich_fog = false if $game_system.respond_to?(:rich_fog=)
          $game_system.end_noise if $game_system.respond_to?(:end_noise)
        end
        $game_map.screen.start_flash(Color.new(221, 221, 221, 255), 40) if $game_map.screen
      end

      # Variant 2 — the CE55 visual sequence (minus state writes / BGM / buff) as an event-
      # command list, run on the idle map interpreter. Honors the per-peer effects-off switch.
      def fx_list(on)
        l = []
        on ? build_activate(l) : build_deactivate(l)
        l << RPG::EventCommand.new(0, 0, [])  # list terminator
        l
      end

      def build_activate(l)
        se(l, "空间法术 (2)", 80, 70)  # 空间法术 (2)
        unless $game_switches[EFFECTS_OFF]
          script(l, ["map_effects.set_radial_blur(50, 60)",
                     "map_effects.set_zoom_blur(50, 60)",
                     "map_effects.setup_blur(4, 50, 5, 60)"])
          wait(l, 60)
          script(l, ["map_effects.set_radial_blur(0, 60)",
                     "map_effects.set_zoom_blur(100, 60)",
                     "map_effects.setup_blur(4, 0, 0, 60)"])
        end
        se(l, "Ice7", 80, 130)
        flash(l)
        script(l, ["map_effects.set_tone(0, 0, 0, 180, 60)"])
        script(l, ["rich_fog_start"])
      end

      def build_deactivate(l)
        unless $game_switches[EFFECTS_OFF]
          script(l, ["map_effects.set_zoom_blur(100, 60)",
                     "map_effects.setup_blur(4, 0, 0, 60)"])
          wait(l, 10)
          script(l, ["map_effects.set_zoom_blur(100, 60)",
                     "map_effects.setup_blur(4, 0, 0, 60)"])
        end
        script(l, ["map_effects.set_color(0, 0, 0, 0, 60)",
                   "map_effects.set_tone(0, 0, 0, 0, 60)"])
        flash(l)
        script(l, ["rich_fog_stop"])
        script(l, ["end_noise"])
      end

      # --- event-command builders (code, indent 0, parameters) ---
      def script(l, lines)
        l << RPG::EventCommand.new(355, 0, [lines[0]])           # Script (first line)
        lines[1..-1].each { |ln| l << RPG::EventCommand.new(655, 0, [ln]) }  # ScriptMore
      end

      def wait(l, frames)
        l << RPG::EventCommand.new(230, 0, [frames])             # Wait
      end

      def flash(l)
        l << RPG::EventCommand.new(224, 0, [Color.new(221, 221, 221, 255), 40, false])  # Flash Screen
      end

      def se(l, name, volume, pitch)
        l << RPG::EventCommand.new(250, 0, [RPG::SE.new(name, volume, pitch)])  # Play SE
      end
    end
  end
end

#==============================================================================
# ■ Game_Switches — play the beacon FX when switch 20 arrives from the network
#==============================================================================
# Wraps 1240's broadcast alias. A local toggle has $bsmp_applying_fact = false here (and
# already played CE55's FX), so it's skipped; only a network-applied flip mirrors the anim.
class Game_Switches
  alias bsmp_beaconfx_set []=
  def []=(switch_id, value)
    old = self[switch_id]
    bsmp_beaconfx_set(switch_id, value)
    if switch_id == BSMP::BeaconFX::SWITCH and $bsmp_applying_fact and
       ((old ? true : false) != (value ? true : false))
      BSMP::BeaconFX.on_remote_toggle(value ? true : false)
    end
  end
end

#==============================================================================
# ■ Scene_Map — re-apply the persistent beacon fog on map entry
#==============================================================================
# Covers entering a map (or loading a save / syncing the host's world on join) while the
# time-overlap device is already ON: the per-map autorun that would restore the fog is
# suppressed on a non-owner, and on join switch 20 is set before we reach Scene_Map. start
# fires on load / return-from-battle; post_transfer fires on walk-between-maps. Idempotent.
class Scene_Map
  alias bsmp_beaconfx_start start
  def start
    bsmp_beaconfx_start
    BSMP::BeaconFX.apply_persistent
  end

  alias bsmp_beaconfx_post_transfer post_transfer
  def post_transfer
    bsmp_beaconfx_post_transfer
    BSMP::BeaconFX.apply_persistent
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-BeaconFX"]
