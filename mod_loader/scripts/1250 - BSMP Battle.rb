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
    @pending_mirror_ce = nil # a received MIRROR_CE id to run on the map (death/loss outcome)

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

      # Battle result. Set when battle ended
      # -1 - unknown battle result
      attr_accessor :result

      # A common-event id the battle authority mirrored to us (MIRROR_CE) for the
      # death/loss outcome; consumed on the map by bsmp_consume_mirror_ce.
      attr_accessor :pending_mirror_ce

      # Host only: [requester_id, [actor_snapshot, ...]] from a BATTLE_REQUEST — the
      # requester's full battle party (incl event-added temp allies not in the troop),
      # built into proxies at the host's Scene_Battle#start so they fight from turn one.
      attr_accessor :pending_roster

      def begin_client_session
        @active = true
        @ending = false
        @starve = 0
        @status_dirty = false
        @result = nil
      end

      # Coalesce battle-status redraws. Every BATTLE_SYNC (enemies) and BATTLE_PARTY_SYNC
      # (allies) used to call refresh_status/refresh_ap itself — two full redraws per sync
      # window, each regenerating AP-gauge bitmaps while AP charges, which tanked the FPS.
      # Instead mark dirty here and redraw at most ONCE per frame (mute Scene_Battle#update).
      def mark_status_dirty
        @status_dirty = true
      end

      def consume_status_dirty
        d = @status_dirty
        @status_dirty = false
        d
      end

      def consume_battle_result
        r = @result
        @result = nil
        r
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
        # Don't reset result, instead do it in on_map_end_client_session
      end

      # Called in map, when the battle just ended
      def on_map_end_client_session
        @result = nil
      end

      def begin_host_session
        @host_active = true
        @sync_tick   = 0
      end

      def end_host_session
        @host_active = false
      end

      # True while we're on a battle-equip excursion. BS2's in-battle "equip" command
      # (script 171) leaves the battle scene to open Scene_Equip and re-enters it on
      # return, with $game_temp.battle_equip set across the whole round trip. The co-op
      # layer must NOT treat that as a real battle end/start — otherwise the host's
      # terminate BATTLE_ENDs every guest (immediate kick) and the proxy/input state gets
      # wiped ("alone in battle"). Every battle teardown/rebuild hook checks this.
      # respond_to? guards a game without script 171.
      def equip_excursion?
        t = $game_temp
        (t and t.respond_to?(:battle_equip) and t.battle_equip) ? true : false
      end

      # True when we're (logically) inside the battle: the active scene is Scene_Battle,
      # OR we're on a BS2 in-battle equip excursion (Scene_Equip opened mid-fight is still
      # part of the battle, just a sub-screen). Lets the stale-session safety net tell a
      # genuinely orphaned session apart from one that's only briefly outside Scene_Battle.
      def is_battle_scene?
        s = SceneManager.scene
        (s.is_a?(Scene_Battle)) or equip_excursion?
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
      def request_end(result)
        @ending = true
        @result = result
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
        # Leading segment: the battle screen tone (r.g.b.gray). Battle-start tints come
        # from troop events, which guests don't run, so mirror the tone continuously —
        # this also catches a guest that joined after the tint was applied.
        t = $game_troop.screen.tone
        parts = ["#{t.red.to_i}.#{t.green.to_i}.#{t.blue.to_i}.#{t.gray.to_i}"]
        $game_troop.members.each_with_index do |e, i|
          turns = e.instance_variable_get(:@state_turns) || {}
          st = e.states.map { |s| "#{s.id}:#{turns[s.id] || 0}" }.join('.')
          # Field 5 = live enemy_id, so a mid-battle Enemy Transform (troop command
          # 336, phase-2 bosses) reaches the mute guest — it doesn't run troop events.
          # st uses only '.'/':' so it never eats the comma before enemy_id.
          # Field 6 = hidden? — a boss that spawns reinforcements mid-fight (Enemy Appear,
          # command 335) only un-hides them on the host; mirror it so they show on guests.
          parts << "#{i},#{e.hp},#{e.mp},#{e.ap},#{st},#{e.enemy_id},#{e.hidden? ? 1 : 0}"
        end
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_SYNC, 0, parts.join(';')))
      end

      # Host: re-announce the live battle so anyone on the map gets pulled back in — the
      # shared-battle guarantee (nobody fights/wanders solo while a co-op battle runs). A
      # peer joins a host battle exactly once, via BATTLE_START; if it then leaves the
      # battle scene WITHOUT the host's battle ending — F12 reset + reload save, a late
      # joiner who wasn't in the lobby at start, or a watchdog-starved guest — it's stranded
      # on the map while the fight continues. Re-broadcasting BATTLE_START on a slow throttle
      # heals all of those: a peer not yet in the battle re-enters (on_battle_start ->
      # pending -> bsmp_consume_battle_start), one already a mute client ignores it
      # (on_battle_start early-returns on client_session?), and the host ignores its own.
      # Throttled separately from BATTLE_SYNC; runs only while WE host the battle.
      def host_reannounce_battle
        return if not BSMP.host?
        return if not host_session?
        return if not bsmp_network_running?
        return if $game_troop.nil? or $game_troop.troop.nil?
        @reannounce_tick = (@reannounce_tick || 0) + 1
        return if @reannounce_tick % BSMP::Config::BATTLE_REANNOUNCE_INTERVAL != 0
        data = "#{$game_map.map_id};#{$game_troop.troop.id};#{BattleManager.can_escape? ? 1 : 0}"
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_START, 0, data))
      end

      # Host: an action is about to play an animation on its targets — push it so the
      # mute guest plays the same (setting battler.animation_id, like the map balloon).
      # Enemy targets only (actor side is the guest's own party until 6.3). animation_id
      # is already resolved here (weapon anim for normal attacks); <= 0 means no anim.
      # Owner id of a party battler for the wire: a proxy carries its owner, our own
      # actors carry the host's id. Lets a guest map ally targets back by identity
      # (battle_members order differs per peer, so a raw index would be wrong).
      def bsmp_owner_of(battler)
        return battler.bsmp_owner if battler.is_a?(Game_BSMPProxyActor)
        $bsmp_server ? $bsmp_server.server_user_id : 0
      end

      # Host: push an action animation. Enemy targets ride a troop index; ALLY targets
      # ride (owner.actor_id) so the guest plays it on the right party member — this is
      # also how the per-hit red flash baked into an attack animation reaches the guest
      # (it plays on the target sprite, not Game_Screen). data =
      # "anim_id;mirror;enemy_idx,..;owner.aid,..".
      def host_broadcast_anim(targets, animation_id, mirror)
        return if not bsmp_network_running?
        return if animation_id.nil? or animation_id <= 0
        enemies = targets.select { |t| t.enemy? }.map { |t| t.index }
        actors  = targets.select { |t| t.actor? }.map { |t| "#{bsmp_owner_of(t)}.#{t.id}" }
        return if enemies.empty? and actors.empty?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_ANIM, 0,
          "#{animation_id};#{mirror ? 1 : 0};#{enemies.join(',')};#{actors.join(',')}"))
      end

      # Host: an action just resolved against one target — push the result so the mute
      # guest shows the same damage pop-up (BS2's script 154 reads battler.result +
      # battler.damage=). Enemy targets only. HP/MP/TP are the per-hit deltas (the
      # pop-up number); the absolute HP still arrives via BATTLE_SYNC.
      def host_broadcast_result(target)
        return if not bsmp_network_running?
        if target.enemy?
          tgt = "e:#{target.index}"
        elsif target.actor?
          tgt = "f:#{bsmp_owner_of(target)}.#{target.id}" # ally pop-up, keyed by identity
        else
          return
        end
        r = target.result
        flags = (r.missed ? 1 : 0) | (r.evaded ? 2 : 0) | (r.critical ? 4 : 0)
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_RESULT, 0,
          "#{tgt};#{r.hp_damage};#{r.mp_damage};#{r.tp_damage};#{flags}"))
      end

      # Client: Process battle end, e.g. from BATTLE_END from host or watchdog abort
      def client_battle_return
        # The host already showed (and mirrored, with the all-confirm barrier) the
        # victory/defeat messages while we were in the mute battle. Run the result for its
        # control flow only — suppress its $game_message lines so they don't appear a second
        # time now, after BATTLE_END. The flag is tight (just this call) and always reset.
        BSMP::BattleMsg.suppress_local = true if defined?(BSMP::BattleMsg)
        begin
          # Call methods like game, when result is known
          if not @result.nil?
              return BattleManager.process_victory if @result == 0
              return BattleManager.process_abort   if @result == 1
              return BattleManager.process_defeat  if @result == 2
          end
        ensure
          BSMP::BattleMsg.suppress_local = false if defined?(BSMP::BattleMsg)
        end
        # Emergency abort the battle if result unset (host disconnected / watchdog abort)
        SceneManager.return
        # Bug: client mute interpreter, so BattleManager.battle_end won't get called.
        # This leads to skip $game_party.on_battle_end, that clears @in_battle flag,
        # so almost all the Game_Interpreter events are skipped
        $game_party.on_battle_end
        $game_troop.on_battle_end
      end

      # Host: send battle start to all clients. Only the lobby host starts co-op
      # battles — guests that touch a hostile send BATTLE_REQUEST and the host runs
      # the actual battle here. (Map-owner authority is for MOB simulation only.)
      def host_ensure_battle(troop_id, can_escape)
        return if not BSMP.host?
        return if host_session?  # Already initialized
        data = "#{$game_map.map_id};#{troop_id};#{can_escape ? 1 : 0}"
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_START, 0, data))
        BSMP::Battle.begin_host_session # start streaming troop state to guests
      end
    end
  end

  module Events
    # --- co-op battle lifecycle (step 6.1) ---

    # Map owner entered a battle: ALL non-battle-hosts join as mute clients, no
    # matter which map they're standing on — co-op battles are global ("fight
    # together"). data still carries map_id first (context for the troop's origin,
    # not used as a filter). Guard is host_session? (true only on the peer that
    # started the battle), NOT map_owner_here? — that would block the lobby host
    # from joining a guest-owned map's battle.
    def self.on_battle_start(packet)
      return if BSMP::Battle.host_session?  # we're the one who started this battle
      return if BSMP::Battle.client_session? # already in the host's battle
      _, troop_id, can_escape = packet.data.split(';')
      BSMP::Battle.pending = { :troop_id => troop_id.to_i, :can_escape => (can_escape.to_i != 0) }
    end

    # Battle owner's battle ended (result 0 win / 1 escape (abort) / 2 lose). Leave
    # the mute battle scene and return to the map. If we never finished entering (a
    # fast start->end race), just drop the queued start.
    def self.on_battle_end(packet)
      return if BSMP::Battle.host_session?  # the owner's own end already ran locally
      result = packet.data.to_i
      BSMP::Battle.pending = nil
      BSMP::Battle.request_end(result) if BSMP::Battle.client_session?
    end

    # Co-op death/loss mirror (step 6.5). The battle authority's real IfLose called a
    # shared common event (death); run the SAME one here so the whole party shares the
    # outcome. Deferred to the map (bsmp_consume_mirror_ce) so we don't setup the map
    # interpreter mid scene-transition. The id is validated against the whitelist so a
    # peer can't drive us into an arbitrary common event.
    def self.on_mirror_ce(packet)
      id = packet.data.to_i
      return unless BSMP.shared_ce?(id)
      BSMP::Battle.pending_mirror_ce = id
    end

    # Host's troop-state broadcast: mirror enemy HP/MP/ATB onto our copies so the
    # mute scene's bars/gauges track the real fight. Same DB + troop_id, so indices
    # line up with our $game_troop.members. Setting hp= refreshes the battler (death
    # state etc.); the enemy sprites/HP bars read these each frame, so no explicit
    # redraw is needed. Actor side is untouched here (combined party = 6.3).
    def self.on_battle_sync(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      BSMP::Battle.note_sync # heartbeat: the host is still streaming this battle
      return if $game_troop.nil?
      entries = packet.data.split(';')
      # Leading segment = the host's battle screen tone; snap to it when it differs (so
      # a battle-start gray tint shows even though we never ran the troop tint event).
      tone_seg = entries.shift
      if tone_seg and $game_troop.screen
        tr, tg, tb, tgr = tone_seg.split('.').map { |s| s.to_i }
        c = $game_troop.screen.tone
        if c.red.to_i != tr or c.green.to_i != tg or c.blue.to_i != tb or c.gray.to_i != tgr
          $game_troop.screen.start_tone_change(Tone.new(tr, tg, tb, tgr), 0)
        end
      end
      entries.each do |entry|
        f = entry.split(',')
        next if f.size < 4
        e = $game_troop.members[f[0].to_i]
        next if e.nil?
        # Mid-battle Enemy Transform (phase-2 boss): the host's enemy_id changed but the
        # troop command that did it never ran here. Mirror it so the battler graphic
        # (Sprite_Battler#update_bitmap watches battler_name), name and mhp follow. Do it
        # BEFORE writing hp/states below, since transform's refresh re-derives them.
        if f[5] and f[5].to_i > 0 and e.respond_to?(:transform) and e.enemy_id != f[5].to_i
          e.transform(f[5].to_i)
        end
        # Mirror appear/hide (Enemy Appear, command 335): boss reinforcements spawn only on
        # the host. Match it so the new enemy's sprite shows (or hides) on the guest too.
        if f[6] and e.hidden? != (f[6].to_i != 0)
          f[6].to_i != 0 ? e.hide : e.appear
        end
        was_alive = e.alive?
        # States straight from the host (icons + dead?). Set the ivars directly: this is
        # a pure visual mirror, so we don't want add_state/remove_state side effects, and
        # @hp must NOT go through hp= (its refresh would re-derive the death state from hp
        # and fight the host's authoritative @states). @state_turns kept in step so any
        # turn lookups stay valid.
        ids = []
        turns = {}
        (f[4] || "").split('.').each do |spec|
          sid, t = spec.split(':')
          sid = sid.to_i
          ids << sid
          turns[sid] = t.to_i
        end
        e.instance_variable_set(:@state_turns, turns)
        e.instance_variable_set(:@states, ids)
        e.instance_variable_set(:@hp, f[1].to_i)
        e.mp = f[2].to_i
        e.ap = f[3].to_i
        # Mirror the death fade when the enemy crosses into dead (states alone don't fade
        # the sprite). Catches every death source, synced to when the guest sees it die.
        e.perform_collapse_effect if was_alive and e.dead?
        # Drive the big MOG boss HP bar (script 293). It reads $game_system.boss_hp_meter[],
        # refreshed by check_boss_hp_after — an item_apply hook that NEVER fires on the mute
        # guest (we set @hp directly). So the bar froze at the start value. Replicate exactly
        # what check_boss_hp_after writes, here, for the boss enemy we just synced (covers a
        # transformed boss too: name/mhp/material id follow the new enemy_id).
        if e.respond_to?(:boss_hp_meter) and e.boss_hp_meter and $game_system.boss_hp_meter
          bm = $game_system.boss_hp_meter
          bm[2]  = true
          bm[3]  = e.name
          bm[4]  = e.hp
          bm[5]  = e.mhp
          bm[7]  = (e.level rescue nil)
          bm[9]  = e.boss_hp_number
          bm[11] = e.boss_hp_meter_id
        end
      end
      # BS2's enemy gauges (177: HP/MP/TP and the AP bar) are bitmap-drawn ON DEMAND via
      # refresh_status / refresh_ap, not per frame. Mark the status dirty; the mute scene
      # redraws once next frame (coalesced — see mark_status_dirty).
      BSMP::Battle.mark_status_dirty
    end

    # Host pushed an action animation: play it on our copies of the enemy targets by
    # setting animation_id (Sprite_Battler picks it up next frame, like the map balloon).
    def self.on_battle_anim(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      f = packet.data.split(';')
      anim_id = f[0].to_i
      mir = (f[1].to_i == 1)
      # Enemy targets (troop index).
      if $game_troop
        (f[2] || "").split(',').each do |s|
          next if s.empty?
          e = $game_troop.members[s.to_i]
          next if e.nil?
          e.animation_id = anim_id
          e.animation_mirror = mir
        end
      end
      # Ally targets (owner.actor_id) — plays the attack animation (and its baked flash)
      # on the right party member.
      (f[3] || "").split(',').each do |spec|
        next if spec.empty?
        b = BSMP::BattleParty.resolve_ally(spec)
        next if b.nil?
        b.animation_id = anim_id
        b.animation_mirror = mir
      end
    end

    # Host pushed a per-enemy action result: reproduce the damage pop-up. We feed the
    # host's values into the target's result and trigger BS2's pop-up (script 154's
    # battler.damage=), which reads result.hp/mp/tp + critical/missed/evaded. The
    # collapse and the absolute HP are handled by on_battle_sync.
    def self.on_battle_result(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      tgt, hp, mp, tp, flags = packet.data.split(';')
      if tgt.to_s.start_with?('e:')
        e = $game_troop ? $game_troop.members[tgt[2..-1].to_i] : nil
      elsif tgt.to_s.start_with?('f:')
        e = BSMP::BattleParty.resolve_ally(tgt[2..-1])
      end
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
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil? or $game_troop.screen.nil?
      r, g, b, a, dur = packet.data.split(';').map { |s| s.to_i }
      $game_troop.screen.start_flash(Color.new(r, g, b, a), dur)
    end

    # Host's battle screen shook: reproduce it with the host's exact power/speed/duration
    # (the variable per-hit shake the host shows). No actor needed.
    def self.on_battle_shake(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil? or $game_troop.screen.nil?
      power, speed, dur = packet.data.split(';').map { |s| s.to_i }
      $game_troop.screen.start_shake(power, speed, dur)
    end

    # Host's enemy is about to act: play the pre-attack white blink on our copy.
    def self.on_battle_whiten(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      return if $game_troop.nil?
      e = $game_troop.members[packet.data.to_i]
      e.sprite_effect_type = :whiten if e
    end

    # Host swapped the battle background mid-fight (event command 283): apply the same
    # battleback here. change_battleback (script 180) repaints our mute scene's spriteset.
    def self.on_battle_back(packet)
      return if BSMP::Battle.host_session?  # we're streaming this; ignore our own echo
      return if not BSMP::Battle.client_session?
      return if $game_map.nil?
      bb1, bb2 = packet.data.to_s.split("\n", -1)
      $game_map.change_battleback(bb1.to_s, bb2.to_s)
    end

    # The peer that ran a co-op battle event did a post-battle TransferPlayer (IfWin —
    # boss victory warp, or a kill that moves to another map). We were a mute client and
    # never ran that branch, so we'd be left behind. Reserve the SAME transfer; it
    # performs once we're back on our map (reserve_transfer is just ivars, safe to set
    # even while still in the mute battle scene). dir 0 = keep facing (stock semantics).
    # This isn't command_201, so it never re-broadcasts — no echo.
    def self.on_story_transfer(packet)
      return unless bsmp_network_running?
      map_id, x, y, dir = packet.data.to_s.split(';').map { |s| s.to_i }
      return if map_id <= 0
      $game_player.reserve_transfer(map_id, x, y, dir)
    end

    HANDLERS[STORY_TRANSFER] = method(:on_story_transfer)
    HANDLERS[BATTLE_BACK]   = method(:on_battle_back)
    HANDLERS[BATTLE_START]  = method(:on_battle_start)
    HANDLERS[BATTLE_END]    = method(:on_battle_end)
    HANDLERS[BATTLE_SYNC]   = method(:on_battle_sync)
    HANDLERS[BATTLE_ANIM]   = method(:on_battle_anim)
    HANDLERS[BATTLE_RESULT] = method(:on_battle_result)
    HANDLERS[BATTLE_FLASH]  = method(:on_battle_flash)
    HANDLERS[BATTLE_SHAKE]  = method(:on_battle_shake)
    HANDLERS[BATTLE_WHITEN] = method(:on_battle_whiten)
    HANDLERS[MIRROR_CE]     = method(:on_mirror_ce)

    # Non-host peer asked us (the lobby host) to start a co-op battle for them —
    # they touched a hostile on a map we may not be standing on. We start the real
    # Scene_Battle; the existing BattleManager.setup / Scene_Battle#start hooks will
    # broadcast BATTLE_START so everyone (the requester + any other guests) join as
    # mute clients. We don't set event_proc on our side: the requester's interpreter
    # owns the post-battle branches (IfWin / IfLose run there via @branch).
    def self.on_battle_request(packet)
      return unless BSMP.host?
      return unless bsmp_network_running?
      return if $game_party.in_battle          # already in one
      return if BSMP::Battle.host_session?     # a co-op battle is already starting/live
      # (e.g. several gated peers fired command_301 at once — the host's own start wins,
      #  the redundant requests are dropped; everyone joins via the one BATTLE_START)
      header, *roster = packet.data.to_s.split("\n")
      troop_id, can_escape, can_lose = header.split(';').map { |s| s.to_i }
      return unless $data_troops[troop_id]
      # Remember the requester's full party (snapshots) so Scene_Battle#start can build
      # proxies of its event-added temp allies — see the start hook below.
      BSMP::Battle.pending_roster = [packet.from_id, roster]
      BattleManager.setup(troop_id, can_escape != 0, can_lose != 0)
      $game_player.make_encounter_count
      SceneManager.call(Scene_Battle)
    end
    HANDLERS[BATTLE_REQUEST] = method(:on_battle_request)
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
    # Capture BEFORE the original start: BS2's battle_start (171) clears
    # $game_temp.battle_equip DURING it, so checking equip_excursion? afterwards would miss
    # the equip-return case and wrongly re-broadcast BATTLE_START to guests that never left
    # (which kicks them with no recovery). The co-op battle is already live on return.
    excursion = BSMP::Battle.equip_excursion?
    bsmp_battle_scene_start
    if BSMP.host? and bsmp_network_running? and not excursion
      BSMP::Battle.host_ensure_battle($game_troop.troop.id, BattleManager.can_escape?)
      # Build the requester's party proxies now — the session is live (host_ensure_battle
      # set it) and the start-of-battle proxy clear (1251) has run, so these survive and
      # are in the combined party from turn one. Covers temp allies (e.g. a story
      # companion ChangePartyMember'd in by the requester's event) the host can't learn
      # about from the troop_id alone. apply_snapshot is keyed by (owner, actor_id), so a
      # later live BATTLE_ACTOR just refreshes these instead of duplicating.
      r = BSMP::Battle.pending_roster
      if r
        owner, snaps = r
        snaps.each { |s| BSMP::BattleParty.apply_snapshot(owner, s) }
        BSMP::Battle.pending_roster = nil
      end
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
      # Leave on the owner's BATTLE_END, or as a fallback if we lost the network
      # entirely (disconnect). The "not BSMP.guest?" guard used to be the fallback,
      # but with map-owner semantics the lobby host can ALSO be a mute client (when
      # a guest owns the map and started the battle); "not guest?" would trip on the
      # host and yank it out of the battle on the first frame. Use the network running
      # flag instead — true even for the host-as-mute-client.
      if BSMP::Battle.ending? or not bsmp_network_running?
        BSMP::Battle.end_client_session
        BSMP::Battle.client_battle_return
      # Heartbeat watchdog: the owner has gone silent (its battle ended and we missed
      # the BATTLE_END — e.g. across an F12 reset that dropped us back into a battle
      # the owner already left). Force out to the map; goto, not return, since an F12
      # reset may have left no map scene on the stack to pop back to.
      elsif BSMP::Battle.starved?
        BSMP::Battle.end_client_session
        BSMP::Battle.client_battle_return
      elsif BSMP::Battle.consume_status_dirty
        # Coalesced status redraw: at most once per frame no matter how many sync packets
        # (enemy + ally) arrived, instead of a full refresh per packet (the FPS sink).
        refresh_status if respond_to?(:refresh_status)
        refresh_ap     if respond_to?(:refresh_ap)
      end
    else
      bsmp_battle_scene_update
      if BSMP::Battle.host_session?
        BSMP::Battle.host_broadcast_state
        BSMP::Battle.host_reannounce_battle # pull stragglers/late-joiners back into the fight
      end
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
    # Read incoming packets here too: a blocking emerge/charge wait never reaches
    # Scene_Base#update, so without this the host ignores a joining guest's WORLD_REQUEST
    # for the whole "Появился …" message (the guest hangs until it's dismissed).
    bsmp_net_pump
    if BSMP::Battle.host_session?
      BSMP::Battle.host_broadcast_state
      BSMP::Battle.host_reannounce_battle # re-pull stragglers even during blocking waits
    end
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

  # Mute client: skip the ATB charge loop / command selection that the real battle_start
  # runs. Just initialise the battlers so the troop renders; the host drives everything
  # else. We DO show the emerge banner ("X appeared") locally — the troop is identical, so
  # the text matches the host's, and the mute scene's message window displays + dismisses
  # it (no barrier; it's a battle-start flash, not a host-driven dialogue).
  alias bsmp_battle_scene_battle_start battle_start
  def battle_start
    if BSMP::Battle.client_session?
      # Fresh entry: init the battlers + flash the emerge banner. On a BS2 in-battle equip
      # RETURN the scene re-runs start, so skip both — re-running on_battle_start would reset
      # the mid-fight battler state, and the emerge would re-show "Появился X!" over the party
      # list (the mute scene has no FSM to dismiss it). Only re-open the status window.
      equip_return = BSMP::Battle.equip_excursion?
      unless equip_return
        $game_party.on_battle_start
        $game_troop.on_battle_start
        $game_troop.enemy_names.each do |name|
          $game_message.add(sprintf(Vocab::Emerge, name))
        end
      end
      # The battle status window (the combined-party HUD: rows + HP/MP/AP) is created
      # CLOSED (openness 0) and normally opened in start_party_command_selection — which
      # the mute client never reaches, so it stayed invisible. Open it here. refresh_status
      # keeps redrawing it as the roster (proxies of the other players) streams in (6.3b).
      if @status_window
        @status_window.open
        refresh_status if respond_to?(:refresh_status)
      end
      # The mute client runs THIS battle_start, not BS2's (171) — which is what normally
      # clears $game_temp.battle_equip. battle_start runs in post_start (AFTER Scene#start),
      # so this is the right place to release the flag, once the equip_return guard above has
      # consumed it. Otherwise it stays stuck true and every equip guard never releases.
      $game_temp.battle_equip = false if equip_return and $game_temp.respond_to?(:battle_equip)
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
    # not equip_excursion?: leaving the battle scene to open the in-battle equip menu is
    # NOT the battle ending — without this the host BATTLE_ENDs every guest the instant it
    # opens equip (they're kicked to the map immediately, then re-pulled on return).
    if BSMP.host? and BSMP::Battle.host_session? and bsmp_network_running? and not BSMP::Battle.equip_excursion?
      result = BSMP::Battle.result || -1
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_END, 0, result.to_s))
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
        BSMP::Battle.result = result
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_END, 0, result.to_s))
      end
      BSMP::Battle.end_host_session # stop streaming troop state
      bsmp_battle_end(result)
    end

    # Host-authoritative victory rewards. Stock gain_gold / gain_drop_items call
    # rand via $game_troop (gold_total / make_drop_items) — running that on both
    # host and mute client would diverge. The host applies them stock-locally AND
    # broadcasts each as a LOOT_GAIN packet; a non-host skips the local apply
    # entirely (process_victory still calls these on the mute side, but client_session
    # is already closed by then, so we can't gate on it — we gate on host? instead).
    # Rewards reach the mute peer via on_loot_gain -> command_12X, which also fires
    # the BS2 item popup (script 134) for free.
    alias bsmp_battle_gain_gold gain_gold
    def gain_gold
      return unless BSMP.host? or not bsmp_network_running?
      amount = $game_troop.gold_total
      $game_party.gain_gold(amount)
      if amount > 0
        $game_message.add(sprintf(Vocab::ObtainGold, amount))
      end
      return unless BSMP.host? and bsmp_network_running? and BSMP::Battle.host_session?
      return unless amount > 0
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::LOOT_GAIN, 0, "3;0;#{amount}"))
    end

    alias bsmp_battle_gain_drop_items gain_drop_items
    def gain_drop_items
      # Drops roll rand, so they're host-authoritative and can't be derived on the guest.
      # The host grants + shows the "obtained X" lines + broadcasts each item; guests get
      # them via LOOT_GAIN (which fires the BS2 item popup, script 134). Guest victory
      # screen shows the items as popups rather than message lines — content still arrives.
      return unless BSMP.host? or not bsmp_network_running?
      items = $game_troop.make_drop_items
      items.each do |item|
        $game_party.gain_item(item, 1)
        $game_message.add(sprintf(Vocab::ObtainItem, item.name))
      end
      return unless BSMP.host? and bsmp_network_running? and BSMP::Battle.host_session?
      items.each do |item|
        type, id = bsmp_drop_item_type_id(item)
        next if type.nil?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::LOOT_GAIN, 0, "#{type};#{id};1"))
      end
    end

    # Map a $data_items/weapons/armors entry to (type, id) for LOOT_GAIN (matches
    # 1246 - BSMP Loot.rb: 0=item, 1=weapon, 2=armor, 3=gold).
    def bsmp_drop_item_type_id(item)
      case item
      when RPG::Item   then [0, item.id]
      when RPG::Weapon then [1, item.id]
      when RPG::Armor  then [2, item.id]
      else nil
      end
    end


    # Catch battle early
    alias bsmp_battle_setup setup
    def setup(*args)
      bsmp_battle_setup(*args)
      if BSMP.host? and bsmp_network_running?
        BSMP::Battle.host_ensure_battle($game_troop.troop.id, BattleManager.can_escape?)
      end
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
    bsmp_consume_mirror_ce
    bsmp_check_battle_result
  end

  # Run a death/loss common event the battle authority mirrored to us (MIRROR_CE).
  # Done from the map update (not the packet handler) so the map interpreter is set
  # up cleanly between frames, never mid scene-transition out of the mute battle.
  # Marked @bsmp_local_ce so the Estus refill / soul grant inside it stays per-peer
  # (see 1246) instead of dup-instancing back to everyone.
  def bsmp_consume_mirror_ce
    id = BSMP::Battle.pending_mirror_ce
    return if id.nil?
    return if scene_changing?
    return unless $game_map.interpreter and $data_common_events[id]
    BSMP::Battle.pending_mirror_ce = nil
    $game_map.interpreter.setup($data_common_events[id].list)
    $game_map.interpreter.instance_variable_set(:@bsmp_local_ce, true)
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

  def bsmp_check_battle_result
    return if BSMP::Battle.host_session? # battle owner already runs its own interpreter, so ignore
    return if BSMP::Battle.result.nil? # already cleared or emergency exited
    result = BSMP::Battle.consume_battle_result

    if result == 0 # victory
      
    elsif result == 1 # abort

    elsif result == 2 # defeat
        # Death/loss outcome is no longer assumed here. The battle authority runs the
        # real IfLose and, IF it's a death (a shared common event), mirrors it to us
        # via MIRROR_CE -> bsmp_consume_mirror_ce. A scripted-cutscene loss (switches,
        # no death CE) mirrors nothing, so we correctly DON'T die on it.
    end
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
    # A battle session only makes sense inside the battle. is_battle_scene? counts the real
    # Scene_Battle AND a BS2 in-battle equip excursion (Scene_Equip opened mid-fight) — so
    # we don't abort a live session just because the host stepped into the equip screen
    # (which used to kill its heartbeat and starve the guests out ~5s later).
    if (BSMP::Battle.client_session? or BSMP::Battle.host_session?) and not BSMP::Battle.is_battle_scene?
      BSMP::Battle.abort_sessions
    end
  end
end


#==============================================================================
# ■ Game_Interpreter — non-host: request the host to run the battle, then resume
# the page's IfWin / IfEscape / IfLose branches when the result comes back.
#==============================================================================
class Game_Interpreter
  # command_301 - "Battle start". The host runs it stock. A non-host (regardless of
  # whether it's the map owner — co-op battles are global, host is the single
  # battle authority) never runs the battle locally; instead it asks the host to
  # start it. While waiting it parks its Fiber (yields), so the page doesn't run
  # past command_301 until BATTLE_END has set @branch[@indent] = result.
  alias bsmp_battle_command_301 command_301
  def command_301
    return bsmp_battle_command_301 if not bsmp_network_running?
    if BSMP.host?
      bsmp_battle_command_301      # runs the co-op battle; returns once it's over
      bsmp_arm_post_battle_xfer    # so the IfWin TransferPlayer mirrors to the others
      return
    end
    return if $game_party.in_battle
    bsmp_battle_request_remote     # parks until the host's battle ends, then resumes
    bsmp_arm_post_battle_xfer
  end

  def bsmp_battle_request_remote
    # Resolve troop_id the same way the stock command_301 does (direct / variable /
    # map-encounter). Map-encounter (params[0] == 2) is dropped — it would need
    # simulating the host's encounter table here, not worth it for a rare case.
    case @params[0]
    when 0 then troop_id = @params[1]
    when 1 then troop_id = $game_variables[@params[1]]
    else return  # map encounter: skip
    end
    return unless $data_troops[troop_id]
    can_escape = @params[2] ? 1 : 0
    can_lose   = @params[3] ? 1 : 0
    # Ship our FULL battle party with the request so the host builds proxies of every
    # actor — including event-added temporary allies (a story companion added via
    # ChangePartyMember right before this battle) that are in neither the troop nor our
    # persistent party. The host can't learn about them otherwise: it only gets the
    # troop_id, and our live BATTLE_ACTOR re-sends don't arrive until we've already
    # joined the running fight. Snapshots are \n-joined after the troop header (their
    # own fields are ';'-joined). The host builds them at Scene_Battle#start (1250), so
    # the ally fights from turn one instead of hanging as a ghost nobody drives.
    roster = $game_party.battle_members.
      reject { |a| a.is_a?(Game_BSMPProxyActor) }.
      map { |a| BSMP::BattleParty.snapshot(a) }
    data = "#{troop_id};#{can_escape};#{can_lose}\n#{roster.join("\n")}"
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_REQUEST, 0, data))
    # Wait for the host's BATTLE_START to arrive. The host may take a frame or two
    # (the packet is read on the next Scene_Base#update), so yield until pending.
    BSMP::Battle.pending = nil
    while BSMP::Battle.pending.nil? and bsmp_network_running?
      Fiber.yield
    end
    return unless bsmp_network_running?  # we lost the host — bail, leave the event
    start = BSMP::Battle.pending
    BSMP::Battle.pending = nil
    BSMP::Battle.begin_client_session
    # Mirror the stock command_301's setup: can_lose forced to true so a mute client
    # never trips Scene_Gameover locally; event_proc bridges the host's eventual
    # result back into our @branch so the IfWin/IfEscape/IfLose branches run here.
    BattleManager.setup(start[:troop_id], start[:can_escape], true)
    BattleManager.event_proc = Proc.new { |n| @branch[@indent] = n }
    $game_player.make_encounter_count
    SceneManager.call(Scene_Battle)
    Fiber.yield
  end
end

#==============================================================================
# ■ Co-op battle scaling (step 6.6) — enemies scale with the player count so a
# bigger combined party doesn't trivialise the fight. All multipliers come from
# BSMP.battle_scale (lobby-size based, identical on every peer), so host and guests
# agree on enemy stats. Solo / offline => factor 1.0, untouched.
#==============================================================================

class Game_Enemy < Game_Battler
  # Max HP scales with the party (secondary "longer fight" lever). Applied via
  # param_base so it's baked in before plus/rate/buff and before initialize sets
  # @hp = mhp — the player count is the (stable) lobby size, so the enemy spawns at
  # full scaled HP with no init race. Other params pass through unchanged here;
  # speed is handled on the ATB gain below, not on the agi stat (no accuracy spill).
  alias bsmp_scale_param_base param_base
  def param_base(param_id)
    base = bsmp_scale_param_base(param_id)
    return base unless param_id == 0  # 0 = MHP
    (base * BSMP.battle_scale(BSMP::Config::BATTLE_SCALE_HP_PER_PLAYER)).to_i
  end
end

#==============================================================================
# ■ Game_Map — mirror a mid-battle battleback change to the guests
#==============================================================================
# change_battleback (event command 283, repainted live in-battle by script 180) runs
# only on the host (troop events). While we're hosting a co-op battle, broadcast it so
# every mute guest swaps to the same backdrop. The guest's apply (on_battle_back) goes
# through the same method but never re-broadcasts (it isn't host_session).
class Game_Map
  alias bsmp_battle_change_battleback change_battleback
  def change_battleback(battleback1_name, battleback2_name)
    bsmp_battle_change_battleback(battleback1_name, battleback2_name)
    if BSMP::Battle.host_session? and bsmp_network_running?
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_BACK, 0,
        "#{battleback1_name}\n#{battleback2_name}"))
    end
  end
end

#==============================================================================
# ■ Game_Interpreter — mirror troop-event battle animations (Show Battle Animation)
#==============================================================================
# command_337 plays an animation on a troop enemy (BS2: @params = [enemy_index, anim_id]).
# It's a troop event, so it ran only on the host — the phase-change magic-circle animations
# never showed for guests. Reuse BATTLE_ANIM: the guest's on_battle_anim sets the same
# enemy's animation_id. (Action animations already sync via show_normal_animation; this
# covers the event-driven ones.)
class Game_Interpreter
  alias bsmp_anim_command_337 command_337
  def command_337
    bsmp_anim_command_337
    return unless BSMP::Battle.host_session? and bsmp_network_running?
    anim_id = @params[1].to_i
    return if anim_id <= 0
    idxs = []
    iterate_enemy_index(@params[0]) { |e| idxs << e.index if e.alive? }
    return if idxs.empty?
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_ANIM, 0,
      "#{anim_id};0;#{idxs.join(',')};"))
  end
end

#==============================================================================
# ■ Game_Interpreter — pull the party along on a post-battle story transfer
#==============================================================================
# A co-op battle event's IfWin branch often warps the player (boss arena exit, or a
# kill that moves to another map). That branch runs only in the interpreter of the peer
# who ran the battle (the host on a host-touched fight, the requester on a guest-touched
# one) — the others were mute clients and stayed put. We arm a one-shot marker right
# after the battle returns (command_301 above) and mirror the very next TransferPlayer
# in that same event to the other peers (STORY_TRANSFER -> reserve_transfer).
class Game_Interpreter
  # Fresh event run: drop any stale marker. The post-battle 301 re-arms within the run,
  # so this only clears a marker left over from an IfWin that DIDN'T transfer (belt and
  # suspenders alongside the one-shot consume + @event_id guard in command_201).
  alias bsmp_xfer_setup setup
  def setup(list, event_id = 0)
    @bsmp_post_battle_xfer = false
    bsmp_xfer_setup(list, event_id)
  end

  def bsmp_arm_post_battle_xfer
    return unless bsmp_network_running?
    @bsmp_post_battle_xfer  = true
    @bsmp_post_battle_event = @event_id
  end

  # Broadcast the resolved transfer when (and only when) this interpreter just ran a
  # co-op battle and is still in that same event. Normal map-edge walking transfers are
  # unrelated events — never armed — so they stay personal. One-shot: consumed here so a
  # switch-only IfWin can't leave the marker live for a later transfer in the same event.
  alias bsmp_xfer_command_201 command_201
  def command_201
    if @bsmp_post_battle_xfer and @event_id == @bsmp_post_battle_event and
       bsmp_network_running?
      @bsmp_post_battle_xfer = false
      if @params[0] == 0
        map_id, x, y = @params[1], @params[2], @params[3]
      else
        map_id = $game_variables[@params[1]]
        x      = $game_variables[@params[2]]
        y      = $game_variables[@params[3]]
      end
      dir = @params[4].to_i
      if map_id.to_i > 0
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::STORY_TRANSFER, 0,
          "#{map_id};#{x};#{y};#{dir}"))
      end
    end
    bsmp_xfer_command_201
  end
end

class Game_Battler
  # Primary lever: enemies charge their ATB faster so a larger party doesn't out-act
  # them. Scales the AP gain directly (linear, ATB-only) rather than the agi stat,
  # so accuracy / evasion / turn-order math is untouched. Host-authoritative in
  # practice — a guest's mute scene doesn't tick ATB; it mirrors enemy AP via
  # BATTLE_SYNC — but gating on enemy? keeps it correct everywhere regardless.
  if method_defined?(:ap_gain_point)
    alias bsmp_scale_ap_gain_point ap_gain_point
    def ap_gain_point
      base = bsmp_scale_ap_gain_point
      return base unless enemy?
      base * BSMP.battle_scale(BSMP::Config::BATTLE_SCALE_SPEED_PER_PLAYER)
    end
  end
end

class Spriteset_Battle
  # The combined co-op party can exceed the stock 4 actor sprites (Array.new(4)).
  # Those sprites are dummies BS2 uses to target hit animations / damage pop-ups at
  # actors, so a 5th+ ally would silently show none. Grow the pool to cover the whole
  # party. Extra sprites get a nil battler when the party is smaller (harmless).
  alias bsmp_balance_update_actors update_actors
  def update_actors
    members = $game_party.members
    while @actor_sprites.size < members.size
      @actor_sprites.push(Sprite_Battler.new(@viewport1))
    end
    @actor_sprites.each_with_index do |sprite, i|
      sprite.battler = members[i]
      sprite.update
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Battle"]
