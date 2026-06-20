#==============================================================================
# BSMP Battle Party — combined co-op battle party (step 6.3). A guest's actor is put
# into the host's battle as a PROXY Game_Actor so it fights for real on the host (the
# authority). Each guest sends a snapshot of its battle actor(s); the host rebuilds
# them as Game_BSMPProxyActor (same DB base + the guest's live params/hp/states) and
# appends them to its battle party via member-accessor overrides — no $game_actors
# registration (which caches by actor_id and would collide host vs guest), no
# persistent add_actor (which would survive the battle).
#
# 6.3a (this file): host-side injection + the proxy AUTO-FIGHTS (auto_battle?), so the
# guest's character really appears and acts in the host's battle without stalling on
# input. Deferred: the guest rendering the combined party (6.3b) and real remote-turn
# input replacing the auto-action (6.4).
#
# Why proxies sit in the member accessors and not in @actors / $game_actors:
#  * Game_Party#members = in_battle ? battle_members : all_members, and everything the
#    ATB iterates (alive_members / movable_members / Game_Actor#index) flows from members.
#  * In 71's ATB a battler is inputable? only when it's the current input_battler, so a
#    proxy marked auto_battle? is never asked for input — the ATB auto-resolves its turn.
#  * The accessors only append proxies WHILE a battle session is live (host or client),
#    so a stale list can never leak proxies into the map/menu party.
#
# Loads after the game's Game_Actor / Game_Party (BS2) and after BSMP core/battle
# (1200 / 1240 / 1250).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BattleParty"]
$imported["IDL-BSMP-BattleParty"] = "1.0"

if defined?(BSMP)

# Proxies currently injected into the local battle party (host: the guests' actors;
# guest: will be the others', in 6.3b). Only ever non-empty during a battle.
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

  # 6.3a placeholder: never inputable (no command window for a remote actor), so the ATB
  # auto-resolves its turn. 6.4 replaces this with a real remote-input request.
  def auto_battle?
    true
  end

  # Rewards belong to the owning guest (routed back in 6.5), not this throwaway proxy —
  # so it never levels up / spams level-up messages on the host.
  def gain_exp(exp)
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

  # Reimplemented (not the alias) so the host's own front line is taken from the
  # UNPROXIED all_members[0, max] and the proxies are appended AFTER the cap — otherwise
  # a proxy could be both counted in the host's first N and appended (double), or capped
  # out entirely when the host already has max actors.
  alias bsmp_party_battle_members battle_members
  def battle_members
    host_front = bsmp_party_all_members[0, max_battle_members].select { |a| a.exist? }
    host_front + bsmp_proxies
  end
end

#==============================================================================
# ■ BSMP::BattleParty — snapshot + proxy build + the BATTLE_ACTOR handler
#==============================================================================
module BSMP
  module BattleParty

    # Serialize one of OUR real battle actors for the host to rebuild. Params are the
    # final values (so equips/level/plus are baked in); states are ids; ap is the ATB.
    def self.snapshot(actor)
      p = (0..7).map { |i| actor.param(i) }
      states = actor.states.map { |s| s.id }.join('.')
      [actor.id, actor.name, actor.character_name, actor.character_index,
       actor.face_name, actor.face_index,
       p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
       actor.hp, actor.mp, actor.tp, actor.ap, states].join(';')
    end

    # Build (or refresh) a proxy on the host from a guest snapshot and put it in the
    # battle party. Keyed by (owner, actor_id) so a re-send updates instead of dupes.
    def self.apply_snapshot(owner_id, data)
      f = data.to_s.force_encoding("UTF-8").split(';')
      return if f.size < 19
      actor_id = f[0].to_i
      proxy = $bsmp_battle_proxies.find { |a| a.bsmp_owner == owner_id and a.actor_id == actor_id }
      proxy ||= begin
        a = Game_BSMPProxyActor.new(actor_id)
        a.bsmp_owner = owner_id
        $bsmp_battle_proxies.push(a)
        a
      end
      proxy.instance_variable_set(:@name, f[1])
      proxy.set_graphic(f[2], f[3].to_i, f[4], f[5].to_i)
      proxy.bsmp_params = f[6, 8].map { |s| s.to_i }
      proxy.on_battle_start
      proxy.instance_variable_set(:@states, (f[18] || "").split('.').map { |s| s.to_i })
      proxy.instance_variable_set(:@hp, f[14].to_i)
      proxy.instance_variable_set(:@mp, f[15].to_i)
      proxy.instance_variable_set(:@tp, f[16].to_i)
      proxy.instance_variable_set(:@ap, f[17].to_i)
    end

    def self.clear
      $bsmp_battle_proxies = []
    end

  end

  module Events
    # A player sent one of its battle actors. Only the host builds a real proxy (it runs
    # the authoritative battle); other peers will build render-only proxies in 6.3b.
    def self.on_battle_actor(packet)
      return if not BSMP.host?
      BSMP::BattleParty.apply_snapshot(packet.from_id, packet.data)
    end

    HANDLERS[BATTLE_ACTOR] = method(:on_battle_actor)
  end
end

#==============================================================================
# ■ Scene_Battle — guest sends its actors; everyone drops proxies on exit
#==============================================================================
class Scene_Battle
  # Guest entering the host's battle: send a snapshot of each of our REAL battle actors
  # (never the proxies themselves) so the host can put them in the fight.
  alias bsmp_party_battle_start battle_start
  def battle_start
    bsmp_party_battle_start
    if BSMP::Battle.client_session? and bsmp_network_running?
      $game_party.battle_members.each do |actor|
        next if actor.is_a?(Game_BSMPProxyActor)
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_ACTOR, 0,
          BSMP::BattleParty.snapshot(actor)))
      end
    end
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
