#==============================================================================
# BSMP Battle Party — combined co-op battle party (step 6.3). Every player's actor
# joins ONE host-authoritative battle. A remote player's actor is rebuilt locally as a
# Game_BSMPProxyActor (same DB base + that player's live params/hp/states) and appended
# to the battle roster via member-accessor overrides — no $game_actors registration
# (caches by actor_id and would collide host vs guest on the same save), no persistent
# add_actor (would survive the battle).
#
# 6.3a: HOST side — the host builds proxies of the guests' actors and they AUTO-FIGHT
# (auto_battle?), so a guest's character really acts in the host's authoritative battle.
#
# 6.3b (this revision): EVERY peer renders the COMBINED party. Identity over the wire is
# (owner_user_id, actor_id) — robust even when two players run the SAME save (same
# actor_id). Two flows make it work WITHOUT a peer needing to know its own steam id
# (Steam doesn't expose it to Ruby):
#  * ROSTER (mesh via the host's relay): each peer periodically broadcasts its OWN battle
#    actors (BATTLE_ACTOR). The host relays a guest's packet to all OTHER guests and also
#    processes it. So each peer RECEIVES only the others' actors (never its own — the
#    relay excludes the sender, and the host's own send never loops back) and builds a
#    proxy for each. => everyone builds proxies of everyone-but-itself, no self-id needed.
#  * STATE (host-authoritative): the host streams every battler's live HP/MP/ATB/states
#    (BATTLE_PARTY_SYNC) keyed by (owner, actor_id). A guest applies each entry to its
#    matching proxy; an entry that matches NO proxy must be the guest's OWN actor (it
#    never built a self-proxy) — distinguished from an other-player whose proxy is merely
#    lagging by $bsmp_players (which holds only OTHER players, never self).
#
# On the host the proxies are the authoritative battlers (they fight); on a guest they're
# render-only (the mute scene runs no FSM). Same class, one code path. Real remote-turn
# input replacing auto_battle? is 6.4; rewards routing / orphan cleanup is 6.5.
#
# Loads after the game's Game_Actor / Game_Party (BS2) and after BSMP core/battle
# (1200 / 1240 / 1250).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BattleParty"]
$imported["IDL-BSMP-BattleParty"] = "1.1"

if defined?(BSMP)

# Proxies currently injected into the local battle party — on the host the guests'
# actors, on a guest everyone else's. Only ever non-empty during a co-op battle.
$bsmp_battle_proxies = []

#==============================================================================
# ■ Game_BSMPProxyActor — a remote player's actor, driven on the authority
#==============================================================================
class Game_BSMPProxyActor < Game_Actor
  attr_accessor :bsmp_owner   # from_id of the owning player
  attr_accessor :bsmp_params  # [mhp, mmp, atk, def, mat, mdf, agi, luk] from the snapshot

  # Use the owner's real stats verbatim (already include their equips/level/plus), so
  # the proxy fights with the guest's actual power. Buff/debuff param changes during the
  # fight aren't reflected yet (refinement) — the snapshot value is authoritative.
  def param(param_id)
    @bsmp_params ? @bsmp_params[param_id].to_i : super
  end

  # 6.4: the proxy IS inputable on the host so the ATB enters its command phase — but
  # instead of opening a local window, the host requests the command from the owning
  # guest (see 1252). NOT auto_battle? (that would make the host auto-pick its action and
  # never ask). Irrelevant on a guest (its mute scene asks no one for input).
  def auto_battle?
    false
  end

  # Rewards belong to the owning guest (routed back in 6.5), not this throwaway proxy —
  # so it never levels up / spams level-up messages on the host.
  def gain_exp(exp)
  end

  # Real input-cursor behaviour (needed now the proxy is inputable: BattleManager.
  # next_command advances PAST an actor whose next_command returns false, so a hard
  # `false` here would skip the proxy's turn). Guard the index against nil first — a
  # proxy built mid-turn can reach BattleManager's member scan before its index is set,
  # which used to crash on `>=` (Game_Actor line 680).
  def next_command
    @action_input_index ||= 0
    super
  end

  def prior_command
    @action_input_index ||= 0
    super
  end
end

#==============================================================================
# ■ Game_Party — append the proxies to the battle roster
#==============================================================================
class Game_Party
  # Proxies count only while a co-op battle session is live, so a stale list never
  # pollutes the map/menu party even if cleanup is missed (e.g. an F12 unwind).
  def bsmp_proxies
    return [] unless defined?(BSMP::Battle)
    return [] unless BSMP::Battle.host_session? or BSMP::Battle.client_session?
    $bsmp_battle_proxies || []
  end

  alias bsmp_party_all_members all_members
  def all_members
    bsmp_party_all_members + bsmp_proxies
  end

  # Reimplemented (not the alias) so OUR own front line is taken from the UNPROXIED
  # all_members[0, max] and the proxies are appended AFTER the cap — otherwise a proxy
  # could be both counted in our first N and appended (double), or capped out entirely
  # when we already have max actors.
  alias bsmp_party_battle_members battle_members
  def battle_members
    own_front = bsmp_party_all_members[0, max_battle_members].select { |a| a.exist? }
    own_front + bsmp_proxies
  end
end

#==============================================================================
# ■ BSMP::BattleParty — snapshot, proxy build, state stream, roster broadcast
#==============================================================================
module BSMP
  module BattleParty

    # --- serialize / apply one actor's identity + entry state ---------------

    # Serialize one of OUR real battle actors for peers to rebuild. Params are the final
    # values (so equips/level/plus are baked in); states are ids; ap is the ATB. The
    # hp/mp/tp/ap here are only the ENTRY state — once a proxy exists, the authority owns
    # its live state (host battle / BATTLE_PARTY_SYNC), and re-sends don't reset it.
    def self.snapshot(actor)
      p = (0..7).map { |i| actor.param(i) }
      states = actor.states.map { |s| s.id }.join('.')
      [actor.id, actor.name, actor.character_name, actor.character_index,
       actor.face_name, actor.face_index,
       p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
       actor.hp, actor.mp, actor.tp, actor.ap, states].join(';')
    end

    # Build (or refresh) a proxy from a peer's snapshot. Keyed by (owner, actor_id) so a
    # re-send updates instead of duplicating. Identity/appearance/params are refreshed
    # every time (idempotent); the live HP/MP/TP/ATB/states are set ONLY when the proxy
    # is first built — after that the authority owns them (the host's running battle, or
    # a guest's BATTLE_PARTY_SYNC), so a periodic re-send must not clobber them.
    def self.apply_snapshot(owner_id, data)
      f = data.to_s.force_encoding("UTF-8").split(';')
      return if f.size < 19
      actor_id = f[0].to_i
      proxy = $bsmp_battle_proxies.find { |a| a.bsmp_owner == owner_id and a.id == actor_id }
      fresh = proxy.nil?
      proxy ||= begin
        a = Game_BSMPProxyActor.new(actor_id)
        a.bsmp_owner = owner_id
        $bsmp_battle_proxies.push(a)
        a
      end
      proxy.instance_variable_set(:@name, f[1])
      proxy.set_graphic(f[2], f[3].to_i, f[4], f[5].to_i)
      proxy.bsmp_params = f[6, 8].map { |s| s.to_i }
      proxy.instance_variable_set(:@action_input_index, 0) # never nil (input/next_command)
      if fresh
        proxy.on_battle_start
        apply_state(proxy, f[14], f[15], f[16], f[17], f[18])
      end
    end

    # Mirror live HP/MP/(TP)/ATB/states onto a battler straight from the host. Set the
    # ivars directly (no add_state/hp= side effects); @hp must NOT go through hp= (its
    # refresh would re-derive the death state from hp and fight the host's @states).
    # states_dot is "id" or "id:turns" dot-joined (turns absent -> 0). tp may be nil
    # (BATTLE_PARTY_SYNC omits it) -> left untouched. buffs_dot is "param:level" dot-joined
    # for non-zero param buffs (nil -> untouched, e.g. the initial snapshot).
    def self.apply_state(battler, hp, mp, tp, ap, states_dot, buffs_dot = nil)
      ids = []
      turns = {}
      states_dot.to_s.split('.').each do |spec|
        sid, t = spec.split(':')
        next if sid.nil? or sid.empty?
        sid = sid.to_i
        ids << sid
        turns[sid] = t.to_i
      end
      battler.instance_variable_set(:@states, ids)
      battler.instance_variable_set(:@state_turns, turns)
      battler.instance_variable_set(:@hp, hp.to_i)
      battler.instance_variable_set(:@mp, mp.to_i)
      battler.instance_variable_set(:@tp, tp.to_i) unless tp.nil?
      battler.instance_variable_set(:@ap, ap.to_i)
      unless buffs_dot.nil?
        buffs  = Array.new(8, 0)
        bturns = {}
        buffs_dot.to_s.split('.').each do |spec|
          pid, lvl, t = spec.split(':')
          next if pid.nil? or pid.empty?
          pi = pid.to_i
          next unless pi >= 0 and pi < 8
          buffs[pi]  = lvl.to_i
          bturns[pi] = t.to_i # @buff_turns entry per non-zero buff (icon-turn display reads it)
        end
        battler.instance_variable_set(:@buffs, buffs)
        battler.instance_variable_set(:@buff_turns, bturns)
      end
    end

    # --- roster: broadcast OUR own actors so peers proxy them ----------------

    # (Re)broadcast each of our REAL battle actors (never the proxies) as BATTLE_ACTOR.
    # Periodic (BATTLE_ROSTER_INTERVAL) so a peer joining mid-battle catches up; force on
    # battle entry for an immediate appearance. The host relays a guest's packet to the
    # other guests; the host's own send reaches all guests.
    def self.broadcast_own(force = false)
      return if not bsmp_network_running?
      return if $game_party.nil?
      unless force
        @roster_tick = (@roster_tick || 0) + 1
        return if @roster_tick % BSMP::Config::BATTLE_ROSTER_INTERVAL != 0
      end
      $game_party.battle_members.each do |actor|
        next if actor.is_a?(Game_BSMPProxyActor)
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_ACTOR, 0, snapshot(actor)))
      end
    end

    # --- state: host streams every party battler's live state ----------------

    # Host only. Broadcast the authoritative live state of every party battler (our own
    # actors + every proxy) so each guest's combined party tracks the fight — its render
    # proxies of the others AND its own actor (damaged on the host's proxy of it). Keyed
    # by (owner, actor_id). Throttled to the enemy-sync cadence. Entry:
    # "owner.actor_id,hp,mp,ap,id:turns.id:turns".
    def self.host_broadcast_party
      return if not bsmp_network_running?
      return if $game_party.nil? or $bsmp_server.nil?
      @party_tick = (@party_tick || 0) + 1
      return if @party_tick % BSMP::Config::BATTLE_SYNC_INTERVAL != 0
      host_id = $bsmp_server.server_user_id
      parts = []
      $game_party.battle_members.each do |a|
        owner = a.is_a?(Game_BSMPProxyActor) ? a.bsmp_owner : host_id
        turns = a.instance_variable_get(:@state_turns) || {}
        st = a.states.map { |s| "#{s.id}:#{turns[s.id] || 0}" }.join('.')
        # @buffs are param up/down (ATK/DEF…), stored apart from @states — the guest's
        # status icons miss them unless streamed too. Carry the turn count too (@buff_turns):
        # BS2's icon-turn display reads @buff_turns[i].truncate for every non-zero buff, so a
        # missing entry crashes (script 183). Non-zero param levels only, "param:level:turns".
        buffs  = a.instance_variable_get(:@buffs) || []
        bturns = a.instance_variable_get(:@buff_turns) || {}
        bf = []
        buffs.each_with_index { |lvl, i| bf << "#{i}:#{lvl}:#{bturns[i] || 0}" if lvl and lvl != 0 }
        parts << "#{owner}.#{a.id},#{a.hp},#{a.mp},#{a.ap},#{st},#{bf.join('.')}"
      end
      return if parts.empty?
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_PARTY_SYNC, 0, parts.join(';')))
    end

    # Guest: apply the host's party-state broadcast to our combined party. Match each
    # entry to its proxy by (owner, actor_id); an entry with no proxy is OUR own actor
    # (we never built a self-proxy) UNLESS the owner is a known other player (then its
    # proxy is just lagging the roster — skip; the next re-send builds it).
    def self.apply_party_state(data)
      data.to_s.split(';').each do |entry|
        head, rest = entry.split(',', 2)
        next if head.nil? or rest.nil?
        owner_s, aid_s = head.split('.')
        next if owner_s.nil? or aid_s.nil?
        owner = owner_s.to_i
        actor_id = aid_s.to_i
        hp, mp, ap, st, bf = rest.split(',')
        target = $bsmp_battle_proxies.find { |a| a.bsmp_owner == owner and a.id == actor_id }
        if target.nil?
          next if $bsmp_players and $bsmp_players[owner] # other player, proxy pending
          target = $game_party.battle_members.find do |a|
            not a.is_a?(Game_BSMPProxyActor) and a.id == actor_id
          end
        end
        next if target.nil?
        # bf.to_s (never nil) so party sync is authoritative for buffs too: an empty field
        # means "no buffs" and clears stale icons, vs the snapshot which omits buffs (nil).
        apply_state(target, hp, mp, nil, ap, st, bf.to_s)
      end
    end

    # Guest: resolve a wire ally spec "owner.actor_id" to the local battler — a proxy of
    # another player, or (no matching proxy and owner not a known other player) our OWN
    # real actor. Same identity scheme as the party-state stream; used by ally-targeted
    # animations / damage pop-ups (the attack animation carries the per-hit flash).
    def self.resolve_ally(spec)
      dot = spec.to_s.rindex('.')
      return nil if dot.nil?
      owner    = spec[0...dot].to_i
      actor_id = spec[dot + 1..-1].to_i
      proxy = $bsmp_battle_proxies.find { |a| a.bsmp_owner == owner and a.id == actor_id }
      return proxy if proxy
      return nil if $bsmp_players and $bsmp_players[owner] # other player, proxy pending
      $game_party.battle_members.find { |a| (not a.is_a?(Game_BSMPProxyActor)) and a.id == actor_id }
    end

    def self.clear
      $bsmp_battle_proxies = []
    end

  end

  module Events
    # A peer sent one of its battle actors. Build/refresh a proxy whenever we're in a
    # co-op battle — on the host the proxy is authoritative (it fights), on a guest it's
    # render-only. We only ever receive OTHERS' actors (the host's relay excludes the
    # sender), so this never builds a proxy of ourselves.
    def self.on_battle_actor(packet)
      return unless defined?(BSMP::Battle)
      return unless BSMP::Battle.host_session? or BSMP::Battle.client_session?
      BSMP::BattleParty.apply_snapshot(packet.from_id, packet.data)
    end

    # Host's authoritative party-state stream: mirror every battler's HP/MP/ATB/states
    # onto our combined party, then redraw the battle status so the bars step.
    def self.on_battle_party_sync(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      BSMP::BattleParty.apply_party_state(packet.data)
      BSMP::Battle.mark_status_dirty # coalesced redraw (mute Scene_Battle#update)
    end

    HANDLERS[BATTLE_ACTOR]      = method(:on_battle_actor)
    HANDLERS[BATTLE_PARTY_SYNC] = method(:on_battle_party_sync)
  end
end

#==============================================================================
# ■ Scene_Battle — broadcast our actors; stream/render the combined party
#==============================================================================
class Scene_Battle
  # Fresh roster every battle: drop any proxies left over from a previous fight (e.g. an
  # F12 reset that skipped terminate), so a stale/dead clone can't leak into a new battle.
  alias bsmp_party_scene_start start
  def start
    BSMP::BattleParty.clear
    bsmp_party_scene_start
  end

  # On battle entry, immediately broadcast our own actors so the others see us at once
  # (the periodic re-send only fills in stragglers). Both host and guest announce — a
  # guest so the host can put it in the fight, the host so guests render its party.
  alias bsmp_party_battle_start battle_start
  def battle_start
    bsmp_party_battle_start
    if bsmp_network_running? and (BSMP::Battle.host_session? or BSMP::Battle.client_session?)
      BSMP::BattleParty.broadcast_own(true)
    end
  end

  # Drive the periodic party traffic. The host re-announces its actors AND streams every
  # battler's authoritative state; a guest only re-announces its own actors (the host
  # owns state). Runs from both update and update_for_wait (the host spends long stretches
  # in waits — emerge / ATB charge / action resolution — where update doesn't run).
  def bsmp_party_pump
    return if not bsmp_network_running?
    if BSMP::Battle.host_session?
      BSMP::BattleParty.broadcast_own
      BSMP::BattleParty.host_broadcast_party
    elsif BSMP::Battle.client_session?
      BSMP::BattleParty.broadcast_own
    end
  end

  alias bsmp_party_scene_update update
  def update
    bsmp_party_scene_update
    bsmp_party_pump
  end

  alias bsmp_party_scene_update_for_wait update_for_wait
  def update_for_wait
    bsmp_party_scene_update_for_wait
    bsmp_party_pump
  end

  # Drop the proxies whenever we leave a battle scene (any exit path) so the map/menu
  # party is pristine. Harmless on a peer that had none.
  alias bsmp_party_terminate terminate
  def terminate
    BSMP::BattleParty.clear
    bsmp_party_terminate
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-BattleParty"]
