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

  # Co-op battle session state. A guest holds a CLIENT session from the moment it
  # joins the host's battle until BATTLE_END; while active its Scene_Battle is mute.
  # The host holds a HOST session over the same span (its scene is otherwise the
  # normal one) — it just streams its troop's state (BATTLE_SYNC) so the mute guests
  # mirror enemy HP/MP/ATB. Both end at BATTLE_END.
  module Battle
    @active      = false  # are we (a guest) currently a mute client in the host's battle?
    @pending     = nil    # a received BATTLE_START not yet entered (guest still on the map)
    @ending      = false  # BATTLE_END arrived; pop the battle scene on the next client tick
    @host_active = false  # are WE the host running a co-op battle (so we stream state)?
    @sync_tick   = 0      # frame counter for throttling the host's BATTLE_SYNC
    @starve      = 0      # guest frames since the last host state update (heartbeat watchdog)

    class << self
      # True on a guest whose current battle is the host's (so its scene is mute).
      # Always false on the host / single-player, so their Scene_Battle is untouched.
      def client_session?
        @active
      end

      # True on the host while its battle scene is live and networking is up — it
      # streams its troop's state (BATTLE_SYNC) so guests' mute scenes mirror it.
      def host_session?
        @host_active
      end

      # A BATTLE_START we received but haven't entered yet; consumed by
      # Scene_Map#update so the transition happens cleanly between frames.
      attr_accessor :pending

      def begin_client_session
        @active = true
        @ending = false
        @starve = 0
      end

      # Heartbeat watchdog. note_sync resets the starvation counter on every received
      # host state update; client_tick advances it once per mute frame; starved? is
      # true once the host has been silent too long (its battle is over / we missed the
      # BATTLE_END, e.g. across an F12 reset) so the mute scene can bail to the map.
      def note_sync
        @starve = 0
      end

      def client_tick
        @starve += 1
      end

      def starved?
        limit = BSMP.settings.battle_watchdog_frames.to_i
        return false if limit <= 0 # watchdog disabled via settings
        @starve > limit
      end

      def end_client_session
        @active  = false
        @ending  = false
        @pending = nil
      end

      def begin_host_session
        @host_active = true
        @sync_tick   = 0
      end

      def end_host_session
        @host_active = false
      end

      # Drop every battle session. Called when we land on the map/title OUTSIDE a
      # battle scene — e.g. after an F12 reset (RGSSReset) unwinds straight out of the
      # mute Scene_Battle without our update running, leaving client_session stuck true
      # and stranding us "in battle" forever. A fresh map/title means no battle.
      def abort_sessions
        end_client_session
        end_host_session
      end

      # Mark that the host ended the battle; the mute Scene_Battle#update returns to
      # the map on its next tick (doing it there keeps the scene change between frames).
      def request_end
        @ending = true
      end

      def ending?
        @ending
      end

      # Host: broadcast our troop's per-battler state so a guest's mute scene mirrors
      # enemy HP/MP/ATB. Throttled to BATTLE_SYNC_INTERVAL frames. Enemy side only in
      # 6.2 — the actor side is each guest's own party until the combined party (6.3).
      # data = "idx,hp,mp,ap;...", idx = position in $game_troop.members.
      def host_broadcast_state
        return if not bsmp_network_running?
        return if $game_troop.nil?
        @sync_tick += 1
        return if @sync_tick % BSMP::Config::BATTLE_SYNC_INTERVAL != 0
        parts = []
        $game_troop.members.each_with_index do |e, i|
          parts << "#{i},#{e.hp},#{e.mp},#{e.ap},#{e.states.map { |s| s.id }.join('.')}"
        end
        return if parts.empty?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_SYNC, 0, parts.join(';')))
      end

      # Host: an action is about to play an animation on its targets — push it so the
      # mute guest plays the same (setting battler.animation_id, like the map balloon).
      # Enemy targets only (actor side is the guest's own party until 6.3). animation_id
      # is already resolved here (weapon anim for normal attacks); <= 0 means no anim.
      def host_broadcast_anim(targets, animation_id, mirror)
        return if not bsmp_network_running?
        return if animation_id.nil? or animation_id <= 0
        idxs = targets.select { |t| t.enemy? }.map { |t| t.index }
        return if idxs.empty?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_ANIM, 0,
          "#{animation_id};#{mirror ? 1 : 0};#{idxs.join(',')}"))
      end

      # Host: an action just resolved against one target — push the result so the mute
      # guest shows the same damage pop-up (BS2's script 154 reads battler.result +
      # battler.damage=). Enemy targets only. HP/MP/TP are the per-hit deltas (the
      # pop-up number); the absolute HP still arrives via BATTLE_SYNC.
      def host_broadcast_result(target)
        return if not bsmp_network_running?
        return if not target.enemy?
        r = target.result
        flags = (r.missed ? 1 : 0) | (r.evaded ? 2 : 0) | (r.critical ? 4 : 0)
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_RESULT, 0,
          "#{target.index};#{r.hp_damage};#{r.mp_damage};#{r.tp_damage};#{flags}"))
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

    # Host's troop-state broadcast: mirror enemy HP/MP/ATB onto our copies so the
    # mute scene's bars/gauges track the real fight. Same DB + troop_id, so indices
    # line up with our $game_troop.members. Setting hp= refreshes the battler (death
    # state etc.); the enemy sprites/HP bars read these each frame, so no explicit
    # redraw is needed. Actor side is untouched here (combined party = 6.3).
    def self.on_battle_sync(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      BSMP::Battle.note_sync # heartbeat: the host is still streaming this battle
      return if $game_troop.nil?
      packet.data.split(';').each do |entry|
        f = entry.split(',')
        next if f.size < 4
        e = $game_troop.members[f[0].to_i]
        next if e.nil?
        was_alive = e.alive?
        # States straight from the host (icons + dead?). Set the ivars directly: this is
        # a pure visual mirror, so we don't want add_state/remove_state side effects, and
        # @hp must NOT go through hp= (its refresh would re-derive the death state from hp
        # and fight the host's authoritative @states). @state_turns kept in step so any
        # turn lookups stay valid.
        ids = (f[4] || "").split('.').map { |s| s.to_i }
        old_turns = e.instance_variable_get(:@state_turns) || {}
        e.instance_variable_set(:@state_turns, Hash[ids.map { |id| [id, old_turns[id] || 1] }])
        e.instance_variable_set(:@states, ids)
        e.instance_variable_set(:@hp, f[1].to_i)
        e.mp = f[2].to_i
        e.ap = f[3].to_i
        # Mirror the death fade when the enemy crosses into dead (states alone don't fade
        # the sprite). Catches every death source, synced to when the guest sees it die.
        e.perform_collapse_effect if was_alive and e.dead?
      end
      # BS2's enemy gauges (177: HP/MP/TP and the AP bar) are bitmap-drawn ON DEMAND
      # via refresh_status / refresh_ap, not per frame — normally the host's ATB charge
      # loop calls them. The mute scene runs no such loop, so the AP gauge never redrew
      # (invisible). Redraw from the mirrored values. Guarded: these exist only with the
      # enemy-gauge script. draw_gauge? passes on the mute client (enemy alive, in_turn?
      # is false since we never advance past :init).
      scene = SceneManager.scene
      if scene.is_a?(Scene_Battle)
        scene.refresh_status if scene.respond_to?(:refresh_status)
        scene.refresh_ap     if scene.respond_to?(:refresh_ap)
      end
    end

    # Host pushed an action animation: play it on our copies of the enemy targets by
    # setting animation_id (Sprite_Battler picks it up next frame, like the map balloon).
    def self.on_battle_anim(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil?
      anim_id, mirror, idxs = packet.data.split(';')
      anim_id = anim_id.to_i
      mir = (mirror.to_i == 1)
      idxs.to_s.split(',').each do |s|
        e = $game_troop.members[s.to_i]
        next if e.nil?
        e.animation_id = anim_id
        e.animation_mirror = mir
      end
    end

    # Host pushed a per-enemy action result: reproduce the damage pop-up. We feed the
    # host's values into the target's result and trigger BS2's pop-up (script 154's
    # battler.damage=), which reads result.hp/mp/tp + critical/missed/evaded. The
    # collapse and the absolute HP are handled by on_battle_sync.
    def self.on_battle_result(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil?
      idx, hp, mp, tp, flags = packet.data.split(';')
      e = $game_troop.members[idx.to_i]
      return if e.nil?
      fl = flags.to_i
      e.result.clear
      e.result.used      = true
      e.result.missed    = (fl & 1) != 0
      e.result.evaded    = (fl & 2) != 0
      e.result.critical  = (fl & 4) != 0
      e.result.hp_damage = hp.to_i
      e.result.mp_damage = mp.to_i
      e.result.tp_damage = tp.to_i
      e.damage = "damage" # BS2 script 154: build + flag the pop-up from result
    end

    # Host's battle screen flashed: reproduce it with the host's exact color + duration
    # ($game_troop.screen drives Spriteset_Battle's flash, no actor needed).
    def self.on_battle_flash(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil? or $game_troop.screen.nil?
      r, g, b, a, dur = packet.data.split(';').map { |s| s.to_i }
      $game_troop.screen.start_flash(Color.new(r, g, b, a), dur)
    end

    # Host's battle screen shook: reproduce it with the host's exact power/speed/duration
    # (the variable per-hit shake the host shows). No actor needed.
    def self.on_battle_shake(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil? or $game_troop.screen.nil?
      power, speed, dur = packet.data.split(';').map { |s| s.to_i }
      $game_troop.screen.start_shake(power, speed, dur)
    end

    # Host's enemy is about to act: play the pre-attack white blink on our copy.
    def self.on_battle_whiten(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil?
      e = $game_troop.members[packet.data.to_i]
      e.sprite_effect_type = :whiten if e
    end

    HANDLERS[BATTLE_START]  = method(:on_battle_start)
    HANDLERS[BATTLE_END]    = method(:on_battle_end)
    HANDLERS[BATTLE_SYNC]   = method(:on_battle_sync)
    HANDLERS[BATTLE_ANIM]   = method(:on_battle_anim)
    HANDLERS[BATTLE_RESULT] = method(:on_battle_result)
    HANDLERS[BATTLE_FLASH]  = method(:on_battle_flash)
    HANDLERS[BATTLE_SHAKE]  = method(:on_battle_shake)
    HANDLERS[BATTLE_WHITEN] = method(:on_battle_whiten)
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
      BSMP::Battle.begin_host_session # start streaming troop state to guests
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
      BSMP::Battle.client_tick
      # Leave on the host's BATTLE_END, or as a fallback if we lost the host entirely
      # (disconnect / host quit to title). Either way return to the existing map scene.
      if BSMP::Battle.ending? or not BSMP.guest?
        BSMP::Battle.end_client_session
        SceneManager.return
      # Heartbeat watchdog: the host has gone silent (its battle ended and we missed
      # the BATTLE_END — e.g. across an F12 reset that dropped us back into a battle the
      # host already left). Force out to the map; goto, not return, since an F12 reset
      # may have left no map scene on the stack to pop back to.
      elsif BSMP::Battle.starved?
        BSMP::Battle.end_client_session
        SceneManager.goto(Scene_Map)
      end
    else
      bsmp_battle_scene_update
      BSMP::Battle.host_broadcast_state if BSMP::Battle.host_session?
    end
  end

  # Host heartbeat. The battle FSM spends long stretches inside update_for_wait — the
  # emerge-message wait, the ATB charge loop, animation/effect waits — where the normal
  # per-frame update (and so host_broadcast_state) doesn't run. Stream there too, so a
  # guest keeps hearing from us during those pauses and its watchdog never starves on a
  # live battle. host_broadcast_state is self-throttled, so the extra calls are cheap.
  alias bsmp_battle_scene_update_for_wait update_for_wait
  def update_for_wait
    bsmp_battle_scene_update_for_wait
    BSMP::Battle.host_broadcast_state if BSMP::Battle.host_session?
  end

  # Host action replay (step 6.2 slice 2). The host plays the real visuals locally and
  # broadcasts them so the mute guests play the same — animation and damage pop-up —
  # without re-rolling. Both fire only while we're hosting a co-op battle; a guest's
  # mute scene never calls these, and a non-co-op battle has no host session.

  # The concrete animation about to show on the targets (show_attack_animation has
  # already resolved a normal attack to its weapon animation by the time it calls this).
  alias bsmp_battle_scene_show_normal_animation show_normal_animation
  def show_normal_animation(targets, animation_id, mirror = false)
    bsmp_battle_scene_show_normal_animation(targets, animation_id, mirror)
    BSMP::Battle.host_broadcast_anim(targets, animation_id, mirror) if BSMP::Battle.host_session?
  end

  # One target's resolved result (after item_apply, so target.result is populated).
  alias bsmp_battle_scene_apply_item_effects apply_item_effects
  def apply_item_effects(target, item)
    bsmp_battle_scene_apply_item_effects(target, item)
    BSMP::Battle.host_broadcast_result(target) if BSMP::Battle.host_session?
  end

  # The acting subject blinks white just before it acts (execute_action sets :whiten).
  # Mirror it for enemy subjects so the guest sees the same pre-attack tell.
  alias bsmp_battle_scene_execute_action execute_action
  def execute_action
    if BSMP::Battle.host_session? and @subject and @subject.enemy?
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_WHITEN, 0, @subject.index.to_s))
    end
    bsmp_battle_scene_execute_action
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

  # Catch-all battle end. terminate runs when the battle scene is left by ANY path —
  # victory, escape, and crucially BS2's custom defeat / game-over, which can bypass
  # BattleManager.battle_end and so never broadcast BATTLE_END, stranding the guests'
  # mute scenes forever. If our host session is still open here, battle_end didn't
  # fire, so emit the end now. (Normal paths cleared host_session in battle_end, so
  # this won't double-send.) Result is unknown here; guests only use it to leave.
  alias bsmp_battle_scene_terminate terminate
  def terminate
    if BSMP.host? and BSMP::Battle.host_session? and bsmp_network_running?
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_END, 0, "2"))
      BSMP::Battle.end_host_session
    end
    bsmp_battle_scene_terminate
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
      BSMP::Battle.end_host_session # stop streaming troop state
      bsmp_battle_end(result)
    end
  end
end

#==============================================================================
# ■ Game_Screen — mirror the host's genuine battle screen flash / shake
#==============================================================================
# Only effects the host drives through Game_Screen on $game_troop.screen (e.g. a skill
# that flashes/shakes the screen). The per-hit flash baked into an attack animation does
# NOT come through here — it plays on the actor target's sprite, so it arrives naturally
# in 6.3 when the guest's actor is in the fight. We never fabricate a preset; we mirror
# exactly or show nothing, matching the host (normal hits correctly do nothing).
class Game_Screen
  alias bsmp_battle_start_flash start_flash
  def start_flash(color, duration)
    bsmp_battle_start_flash(color, duration)
    if BSMP::Battle.host_session? and $game_troop and equal?($game_troop.screen)
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_FLASH, 0,
        "#{color.red.to_i};#{color.green.to_i};#{color.blue.to_i};#{color.alpha.to_i};#{duration}"))
    end
  end

  alias bsmp_battle_start_shake start_shake
  def start_shake(power, speed, duration)
    bsmp_battle_start_shake(power, speed, duration)
    if BSMP::Battle.host_session? and $game_troop and equal?($game_troop.screen)
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_SHAKE, 0,
        "#{power};#{speed};#{duration}"))
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

#==============================================================================
# ■ Scene_Base — scene-agnostic safety net for stale battle sessions
#==============================================================================
class Scene_Base
  # F12 (RGSSReset) re-yields rgss_main, restarting SceneManager.run from the first
  # scene WITHOUT unwinding our module state — so BSMP::Battle.client_session stays
  # stuck true and strands us "in battle". The first scene after a reset isn't
  # necessarily Scene_Title/Scene_Map (the mod loader may boot a custom scene), so we
  # can't reliably hook a specific start. Instead, check here in the root scene
  # update, which runs every frame in EVERY scene: a battle session only makes sense
  # inside Scene_Battle, so if one is open anywhere else, drop it. (Inside the real
  # mute battle this is a Scene_Battle, so it's untouched.)
  alias bsmp_battle_base_update update
  def update
    bsmp_battle_base_update
    if (BSMP::Battle.client_session? or BSMP::Battle.host_session?) and not is_a?(Scene_Battle)
      BSMP::Battle.abort_sessions
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Battle"]
