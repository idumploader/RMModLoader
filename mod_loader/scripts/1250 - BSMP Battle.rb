#==============================================================================
# BSMP Battle — co-op ATB battle (step 6). Host-authoritative, NOT lockstep: the
# host runs the REAL Scene_Battle (ticks the custom ATB, rolls all RNG, resolves
# actions, decides win/lose) and broadcasts the facts. A guest is a MUTE CLIENT —
# it enters the same battle scene to render the host's troop, but its scene drives
# NOTHING: no ATB tick, no AI, no damage roll, no self win/lose. It only renders +
# pumps the network and pops back to the map when the host says the battle ended.
#
# This file is step 6.1 — the battle SESSION LIFECYCLE only:
#   * the host broadcasts BATTLE_START (its troop) when its battle scene starts and
#     BATTLE_END(result) when BattleManager ends the battle;
#   * a guest, on BATTLE_START, force-enters Scene_Battle (same troop_id, so the
#     same enemies render) as a mute client, then returns to the map on BATTLE_END.
#
# Deferred to later sub-steps (6.2+): authoritative state streaming (ATB / HP /
# states / animations) so the mute scene animates, the combined party (guest actors
# actually in the fight), remote-turn input request/response, scaling, death/DC.
#
# v1 pull-in rule: ALL guests join a host-initiated battle ("fight together"),
# regardless of where they are on the map — simplest, and refined later (6.6) along
# with making guest-touched encounters host-authoritative (today a guest can still
# trigger its own local encounter; that battle stays local and never broadcasts).
#
# Loads after the game's Scene_Battle / BattleManager (BS2 scripts 116 / 161 / 6)
# so the aliases wrap the final versions, and after BSMP core/hooks (1200 / 1240).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Battle"]
$imported["IDL-BSMP-Battle"] = "1.0"

if defined?(BSMP)

module BSMP

  # Co-op battle session state. A "session" exists on a GUEST from the moment it
  # joins the host's battle until BATTLE_END; while it's active the guest's
  # Scene_Battle runs in mute mode. The host has no session in 6.1 — it just
  # broadcasts start/end and runs its normal battle scene unchanged.
  module Battle
    @active  = false   # are we (a guest) currently a mute client in the host's battle?
    @pending = nil     # a received BATTLE_START not yet entered (guest still on the map)
    @ending  = false   # BATTLE_END arrived; pop the battle scene on the next client tick

    class << self
      # True on a guest whose current battle is the host's (so its scene is mute).
      # Always false on the host / single-player, so their Scene_Battle is untouched.
      def client_session?
        @active
      end

      # A BATTLE_START we received but haven't entered yet; consumed by
      # Scene_Map#update so the transition happens cleanly between frames.
      attr_accessor :pending

      def begin_client_session
        @active = true
        @ending = false
      end

      def end_client_session
        @active  = false
        @ending  = false
        @pending = nil
      end

      # Mark that the host ended the battle; the mute Scene_Battle#update returns to
      # the map on its next tick (doing it there keeps the scene change between frames).
      def request_end
        @ending = true
      end

      def ending?
        @ending
      end
    end
  end

  module Events
    # --- co-op battle lifecycle (step 6.1) ---

    # Host entered a battle: join it as a mute client. We're on the map, so just
    # queue it — Scene_Map#update performs the actual transition (mirroring how an
    # encounter enters battle: BattleManager.setup + SceneManager.call).
    def self.on_battle_start(packet)
      return if not BSMP.guest?
      return if BSMP::Battle.client_session? # already in the host's battle
      troop_id, can_escape = packet.data.split(';')
      BSMP::Battle.pending = { :troop_id => troop_id.to_i, :can_escape => (can_escape.to_i != 0) }
    end

    # Host's battle ended (result 0 win / 1 escape / 2 lose). Leave the mute battle
    # scene and return to the map. If we never finished entering (a fast
    # start->end race), just drop the queued start.
    def self.on_battle_end(packet)
      return if not BSMP.guest?
      BSMP::Battle.pending = nil
      BSMP::Battle.request_end if BSMP::Battle.client_session?
    end

    HANDLERS[BATTLE_START] = method(:on_battle_start)
    HANDLERS[BATTLE_END]   = method(:on_battle_end)
  end

end # module BSMP

#==============================================================================
# ■ Scene_Battle — host broadcast + mute-client neutering
#==============================================================================
class Scene_Battle

  # Host: announce the battle to guests when our real battle scene starts, so they
  # join as mute clients rendering the same troop. A guest's own Scene_Battle#start
  # (whether a mute co-op scene or its own local encounter) never broadcasts — the
  # BSMP.host? guard is false there.
  alias bsmp_battle_scene_start start
  def start
    bsmp_battle_scene_start
    if BSMP.host? and bsmp_network_running?
      data = "#{$game_troop.troop.id};#{BattleManager.can_escape? ? 1 : 0}"
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_START, 0, data))
    end
  end

  # Mute-client battle loop: render + pump the network, run NONE of the battle FSM
  # (no ATB tick, no action resolution, no win/lose check). `super` is
  # Scene_Base#update (BSMP-aliased) — it renders via update_basic and reads
  # packets, so BATTLE_END arrives. The host's facts will animate this scene in 6.2+.
  alias bsmp_battle_scene_update update
  def update
    if BSMP::Battle.client_session?
      super
      if BSMP::Battle.ending?
        BSMP::Battle.end_client_session
        SceneManager.return
      end
    else
      bsmp_battle_scene_update
    end
  end

  # Mute client: skip the emerge messages / ATB charge loop / command selection that
  # the real battle_start runs. Just initialise the battlers so the troop renders;
  # the host drives everything else.
  alias bsmp_battle_scene_battle_start battle_start
  def battle_start
    if BSMP::Battle.client_session?
      $game_party.on_battle_start
      $game_troop.on_battle_start
    else
      bsmp_battle_scene_battle_start
    end
  end

end

#==============================================================================
# ■ BattleManager — host broadcasts the authoritative battle end
#==============================================================================
module BattleManager
  class << self
    # Only the host decides the battle is over; mirror that to guests so their mute
    # scenes leave in lockstep. A guest's mute scene never calls battle_end (it runs
    # no win/lose), so this never double-fires across the wire.
    alias bsmp_battle_end battle_end
    def battle_end(result)
      if BSMP.host? and bsmp_network_running?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_END, 0, result.to_s))
      end
      bsmp_battle_end(result)
    end
  end
end

#==============================================================================
# ■ Scene_Map — a guest enters the host's battle as a mute client
#==============================================================================
class Scene_Map

  alias bsmp_battle_map_update update
  def update
    bsmp_battle_map_update
    bsmp_consume_battle_start
  end

  # Enter a queued co-op BATTLE_START as a mute client. Driven from the map's own
  # update (not the packet handler) so we change scenes cleanly between frames,
  # exactly like an encounter: BattleManager.setup + SceneManager.call. The battle
  # visuals (pre_battle_scene / perform_battle_transition) fire from Scene_Map's
  # terminate hooks automatically. can_lose=true so the mute scene can never trip a
  # Game Over even on an edge eval — the host owns win/lose.
  def bsmp_consume_battle_start
    start = BSMP::Battle.pending
    return if start.nil?
    return if scene_changing?
    BSMP::Battle.pending = nil
    BSMP::Battle.begin_client_session
    BattleManager.setup(start[:troop_id], start[:can_escape], true)
    SceneManager.call(Scene_Battle)
  end

end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Battle"]
