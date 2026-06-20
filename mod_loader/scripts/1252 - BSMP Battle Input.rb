#==============================================================================
# BSMP Battle Input — remote-turn input (step 6.4). A guest's actor fights on the host
# as a Game_BSMPProxyActor; now that the proxy is inputable (auto_battle? = false, see
# 1251), the host's ATB enters its command phase when its bar fills. Instead of opening a
# local command window (which would make the HOST control the guest's actor), the host
# asks the OWNING guest for its command and parks the battle on that battler until the
# reply lands (or a timeout auto-resolves it, so an AFK/disconnected guest never hangs the
# fight). The guest decides and replies; the host injects the action into the proxy and
# resumes — the chosen action then resolves through the normal engine, streaming visuals
# to everyone via 6.2.
#
# Engine seams (BS2 "71's ATB", decompile 161/116/6):
#  * Turn-ready funnels through Scene_Battle#start_actor_command_selection (116:329),
#    called from start_party_command_selection (161:47) once a battler hits MAX_AP. We
#    intercept it for proxies.
#  * Command handlers build a Game_Action via input.set_attack / set_skill(id) /
#    set_guard / set_item(id) + input.target_index = idx (116). We rebuild the same from
#    the wire spec.
#  * Scene_Battle#next_command (116:280) advances to the next inputable actor or
#    turn_start. We call it to resume after injecting.
#
# 6.4.0 (this slice): the host request/park/inject/resume/timeout plumbing, with the
# guest AUTO-replying (plain attack on the first living enemy). 6.4.1 replaces the guest's
# auto-reply with a real command window (attack/skill/guard/item + target selection).
#
# Loads after BSMP battle (1250) and battle party (1251).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BattleInput"]
$imported["IDL-BSMP-BattleInput"] = "1.0"

if defined?(BSMP)

module BSMP
  module BattleInput
    # Frames the host waits for a guest's command before auto-resolving its turn. Generous
    # (~30s @ 60fps) so a thinking guest is never cut off; it only catches AFK/disconnect.
    TIMEOUT_FRAMES = 1800

    class << self
      # Drop any parked turn — called on battle start so a stale await can't leak in.
      def reset
        @awaiting = nil   # the proxy whose command we're waiting on (host only)
        @wait     = 0     # frames parked
        @advance  = false # a reply (or fallback) is ready; resume on the next host tick
      end

      def awaiting?
        not @awaiting.nil?
      end

      # Host: a guest's proxy reached its turn. Ask its owner for the command and park the
      # battle here (no local window) until on_reply or the timeout. If the owner isn't
      # connected anymore, auto-resolve at once so the fight doesn't stall.
      def host_request(proxy)
        @awaiting = proxy
        @wait     = 0
        @advance  = false
        return if $bsmp_server.nil?
        client = $bsmp_server.find_client(proxy.bsmp_owner)
        if client
          $bsmp_server.send_packet_to(client,
            BasicNetworkPacket.new(BSMP::Events::BATTLE_INPUT_REQUEST, 0, proxy.id.to_s))
        else
          fallback_auto(proxy)
          @advance = true
        end
      end

      # Host: the owner replied. Validate it's for the parked proxy, build its action, and
      # flag the scene to resume on its next tick (kept off the packet path so the scene
      # state change happens cleanly between frames).
      def on_reply(from_id, data)
        return unless @awaiting
        f = data.to_s.split(';')
        return if f.size < 4
        return unless @awaiting.id == f[0].to_i and @awaiting.bsmp_owner == from_id
        apply_spec(@awaiting, f[1], f[2].to_i, f[3].to_i)
        @advance = true
      end

      # Host per-frame pump (from Scene_Battle#update). Resume when a reply/fallback is
      # ready; otherwise count toward the timeout and auto-resolve if the guest never answers.
      def host_tick(scene)
        return unless @awaiting
        if @advance
          @awaiting = nil
          @advance  = false
          scene.next_command
        else
          @wait += 1
          if @wait > TIMEOUT_FRAMES
            fallback_auto(@awaiting)
            @awaiting = nil
            @advance  = false
            scene.next_command
          end
        end
      end

      # Rebuild a Game_Action on the proxy's current input slot from a wire spec
      # (kind: a=attack g=guard s=skill i=item; obj_id = skill/item id; target_index =
      # index into the troop or party per the action's scope). Guards a vanished
      # skill/item by falling back to a plain attack so a turn is never wasted or errored.
      def apply_spec(proxy, kind, obj_id, target_index)
        act = proxy.input
        return if act.nil?
        case kind
        when 'g' then act.set_guard
        when 's' then act.set_skill(obj_id)
        when 'i' then act.set_item(obj_id)
        else          act.set_attack
        end
        act.target_index = target_index
        if act.item.nil?
          act.set_attack
          act.target_index = first_alive_enemy_index || 0
        end
      end

      # Timeout / no-owner fallback: a plain attack on the first living enemy.
      def fallback_auto(proxy)
        act = proxy.input
        return if act.nil?
        act.set_attack
        act.target_index = first_alive_enemy_index || 0
      end

      def first_alive_enemy_index
        return nil if $game_troop.nil?
        $game_troop.members.each_with_index { |e, i| return i if e and e.alive? }
        nil
      end
    end

    reset
  end

  module Events
    # Guest: the host wants this actor's command. 6.4.0 auto-picks a plain attack on the
    # first living enemy and replies at once (the real command window is 6.4.1). The
    # request is point-to-point, so receiving it means it's for one of our actors.
    def self.on_battle_input_request(packet)
      return if not BSMP.guest?
      return if not BSMP::Battle.client_session?
      actor_id = packet.data.to_i
      target = 0
      if $game_troop
        $game_troop.members.each_with_index do |e, i|
          if e and e.alive?
            target = i
            break
          end
        end
      end
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_INPUT, 0,
        "#{actor_id};a;0;#{target}"))
    end

    # Host: a guest replied with its command — hand it to BattleInput to inject + resume.
    def self.on_battle_input(packet)
      return if not BSMP.host?
      BSMP::BattleInput.on_reply(packet.from_id, packet.data)
    end

    HANDLERS[BATTLE_INPUT_REQUEST] = method(:on_battle_input_request)
    HANDLERS[BATTLE_INPUT]         = method(:on_battle_input)
  end
end

#==============================================================================
# ■ Scene_Battle — host: park proxy turns on remote input
#==============================================================================
class Scene_Battle
  # Fresh battle: clear any parked await from a previous fight (e.g. an F12 unwind).
  alias bsmp_input_scene_start start
  def start
    BSMP::BattleInput.reset
    bsmp_input_scene_start
  end

  # A battler reached its ATB turn. For a guest's proxy, don't open a local command
  # window — request the command from its owner and park (BattleInput). The host's own
  # actors and any non-co-op battle take the normal path.
  alias bsmp_input_start_actor_command_selection start_actor_command_selection
  def start_actor_command_selection
    actor = BattleManager.actor
    if BSMP::Battle.host_session? and actor.is_a?(Game_BSMPProxyActor)
      BSMP::BattleInput.host_request(actor)
    else
      bsmp_input_start_actor_command_selection
    end
  end

  # Host: pump the parked-turn state — resume when the guest's command arrives, or
  # auto-resolve on timeout.
  alias bsmp_input_scene_update update
  def update
    bsmp_input_scene_update
    BSMP::BattleInput.host_tick(self) if BSMP::Battle.host_session?
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-BattleInput"]
