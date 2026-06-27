#==============================================================================
# BSMP BS2 Bonfire Respawn — keep a joining guest from being stranded in the
# co-op world, WITHOUT teaching the generic World snapshot anything about BS2's
# bonfire mechanic. All BS2-specific knowledge lives here; delete this file and
# the mechanic is gone with zero changes elsewhere.
#
# The two problems this solves (both are about a guest's *position* diverging
# from the shared world the host has actually reached):
#
#   1. JOIN onto a host-less map. A guest loads a save on a map the host has
#      never been to. We yank the guest to the host's current position on join.
#
#   2. RESPAWN onto a host-less map. BS2 stores a personal respawn point in
#      variables (CE3 on bonfire rest writes var1=X, var2=Y, var3=MapID; CE12 on
#      death teleports via TransferPlayer([1,3,1,2,...]) = map=var3, x=var1,
#      y=var2). Those vars are personal (not in SHARED_VARIABLE_IDS), so a fresh
#      joiner could die and bounce straight back to a map the host hasn't reached.
#      On join we align the guest's respawn point to the host's, so a death right
#      after joining keeps them together. (Mid-session death clamping is a later
#      slice — see TODO at the bottom.)
#
# HOW THE DATA ARRIVES: the host's respawn point + current position ride along in
# the world snapshot under a private extras key (BSMP::World.register_extra), so
# they're delivered atomically with the world — no extra packet, no race. They are
# NOT shared variables, so they never overwrite the guest's own personal vars 1-3;
# we read them here and decide what to do. If the host is an older build that
# sends no extra, every handler below simply no-ops (defaults stay nil).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BS2-BonfireRespawn"]
$imported["IDL-BSMP-BS2-BonfireRespawn"] = "1.0"

if defined?(BSMP) && defined?(BSMP::World)

module BSMP
  module BonfireRespawn
    # BS2 respawn variables (see CE3 / CE12 above).
    V_X, V_Y, V_MAP = 1, 2, 3

    EXTRA_KEY = :bs2_spawn   # our private slot in the world snapshot
    BLOB_VER  = 1            # sub-version of OUR payload (World never inspects it)

    # --- policy knobs (tune in playtest) -------------------------------------
    # On join, set the guest's respawn point (vars 1-3) to the host's, so a death
    # right after joining doesn't fling them back to a map the host hasn't reached.
    JOIN_ALIGN_RESPAWN = true
    # On join, if the guest loaded onto a DIFFERENT map than the host, transfer the
    # guest to the host's current position (the "loaded a save where the host has
    # never been" case). Same-map joins are left alone.
    JOIN_TELEPORT_HOST = true

    class << self
      # ---- host side: pack respawn point + current position into the snapshot --
      def dump_blob
        w = "".force_encoding("ASCII-8BIT")
        w << [BLOB_VER].pack("C")
        # respawn point (personal vars 1-3 on the host = host's last bonfire)
        World.write_uint(w, nn($game_variables[V_MAP]))
        World.write_uint(w, nn($game_variables[V_X]))
        World.write_uint(w, nn($game_variables[V_Y]))
        # host's live position (for the join-teleport)
        World.write_uint(w, ($game_map ? $game_map.map_id : 0))
        World.write_uint(w, ($game_player ? $game_player.x : 0))
        World.write_uint(w, ($game_player ? $game_player.y : 0))
        World.write_uint(w, ($game_player ? $game_player.direction : 2))
        w
      end

      # ---- guest side: stash the host's data (NO game writes here) -------------
      def load_blob(data)
        @host_respawn = nil
        @host_pos     = nil
        return if data.nil? || data.empty?
        r = World::Reader.new(data)
        return if r.u8 != BLOB_VER          # unknown sub-version -> ignore (forward-compat)
        @host_respawn = [r.uint, r.uint, r.uint]        # [map, x, y]
        @host_pos     = [r.uint, r.uint, r.uint, r.uint] # [map, x, y, dir]
      rescue
        @host_respawn = nil
        @host_pos     = nil
      end

      # Re-arm the once-per-join latch (aliased onto Client#leave_lobby below).
      def reset_session
        @done_for = nil
      end

      # ---- fired after every world apply; acts ONCE per join -------------------
      def on_world_applied
        return unless BSMP.guest?
        return unless $game_player && $game_map
        hid = ($bsmp_client.server_user_id rescue nil)
        return if hid && @done_for == hid   # already handled this session
        @done_for = hid
        align_respawn_to_host        if JOIN_ALIGN_RESPAWN
        teleport_to_host_if_elsewhere if JOIN_TELEPORT_HOST
      end

      # Align our personal respawn point to the host's last bonfire.
      def align_respawn_to_host
        return unless @host_respawn
        hm, hx, hy = @host_respawn
        return if hm.to_i <= 0               # host hasn't rested yet -> nothing to align to
        $game_variables[V_MAP] = hm
        $game_variables[V_X]   = hx
        $game_variables[V_Y]   = hy
        BSMP.debug_log { "[BonfireRespawn] respawn aligned to host bonfire (map=#{hm})" }
      end

      # If we joined onto a different map than the host, go to the host.
      def teleport_to_host_if_elsewhere
        return unless @host_pos
        hm, hx, hy, hd = @host_pos
        return if hm.to_i <= 0
        return if $game_map.map_id == hm     # already with the host -> leave us be
        # reserve_transfer is performed by Scene_Map on its next update (works whether
        # we're mid-load behind the sync overlay or already in-game).
        $game_player.reserve_transfer(hm, hx, hy, hd)
        BSMP.debug_log { "[BonfireRespawn] joined onto map #{$game_map.map_id}; transferring to host map #{hm}" }
      end

      def nn(v) [v.to_i, 0].max end
    end
  end
end

# Carry the host's respawn point + position in the world snapshot. Both peers
# register it; only the relevant direction fires (host dumps, guest loads).
BSMP::World.register_extra(BSMP::BonfireRespawn::EXTRA_KEY,
  proc { BSMP::BonfireRespawn.dump_blob },
  proc { |data| BSMP::BonfireRespawn.load_blob(data) })

# React once the host's world has been applied.
BSMP::World.after_apply { BSMP::BonfireRespawn.on_world_applied }

# Re-arm the once-per-join latch whenever we leave a session (so a rejoin — even to
# the same host — runs the join logic again).
class BSMP::Client
  alias bonfire_respawn_orig_leave_lobby leave_lobby
  def leave_lobby
    BSMP::BonfireRespawn.reset_session
    bonfire_respawn_orig_leave_lobby
  end
end

BSMP.log("[BonfireRespawn] installed\n") if BSMP.respond_to?(:log)

# TODO (next slice): mid-session death clamp. CE12 respawns via vars 1-3; if a guest
# rests far ahead and the host stays behind, a later death still separates them.
# Hook the CE12 respawn transfer and, if the guest's respawn map isn't where the
# host is, redirect to the host's live position (from $bsmp_players). Kept out of the
# join path on purpose — it needs an interpreter/CE hook, not the world-apply hook.

end # defined?(BSMP) && BSMP::World

end # $imported guard
