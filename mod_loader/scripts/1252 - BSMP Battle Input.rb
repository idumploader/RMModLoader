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
#    called from start_party_command_selection (161:47) once a battler hits MAX_AP.
#  * Command handlers build a Game_Action via input.set_attack / set_skill(id) /
#    set_guard / set_item(id) + input.target_index = idx (116). All command+target paths
#    funnel through Scene_Battle#next_command (116:280).
#
# 6.4.0: host request/park/inject/resume/timeout plumbing.
# 6.4.1 (this revision): the guest drives the REAL command UI. On a request it opens its
#   own actor-command window (reusing the game's attack/skill/guard/item + target windows)
#   on its real actor; the single next_command funnel is intercepted to serialize the
#   chosen action onto the wire instead of advancing a (non-running) local turn.
#
# Loads after BSMP battle (1250) and battle party (1251).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BattleInput"]
$imported["IDL-BSMP-BattleInput"] = "1.1"

if defined?(BSMP)

module BSMP
  module BattleInput
    class << self
      # Frames the host waits for a guest's command before auto-resolving its turn
      # (settings-driven, BSMP::Config::BATTLE_INPUT_TIMEOUT default). Generous so a
      # thinking player is never cut off; a true disconnect is caught at once (no owner).
      # Also the length of the guest's on-screen turn timer (6.4.2).
      def timeout_frames
        t = BSMP.settings.battle_input_timeout_frames.to_i
        t > 0 ? t : BSMP::Config::BATTLE_INPUT_TIMEOUT
      end

      # Drop all parked/active input state — called on battle start so nothing leaks in.
      def reset
        @awaiting         = nil   # host: the proxy whose command we're waiting on
        @wait             = 0     # host: frames parked
        @advance          = false # host: a reply/fallback is ready; resume on the next tick
        @escape_requested = false # host: the reply was "flee" -> run command_escape, not an action
        @guest_actor      = nil   # guest: the real actor we're picking a command for
      end

      # --- host side ----------------------------------------------------------

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
        if f[1] == 'e'
          @escape_requested = true # host-authoritative escape, resolved in host_tick
        else
          apply_spec(@awaiting, f[1], f[2].to_i, f[3], from_id)
        end
        @advance = true
      end

      # Host per-frame pump (from Scene_Battle#update). Resume when a reply/fallback is
      # ready; otherwise count toward the timeout and auto-resolve if the guest never answers.
      def host_tick(scene)
        return unless @awaiting
        if @advance
          esc   = @escape_requested
          proxy = @awaiting
          @awaiting         = nil
          @advance          = false
          @escape_requested = false
          if esc
            # Escape is a scene-level (party) decision, so run the host's real
            # command_escape (authoritative RNG roll), not a per-battler action.
            scene.command_escape
          else
            # Re-arm 158's quick-action detection for an injected "no turn cost" item/skill
            # so it executes instantly and re-asks the guest instead of ending the turn.
            it = proxy.input ? proxy.input.item : nil
            scene.instance_variable_set(:@hzm_vxa_quickSkill_skill, it) if quick_item?(it)
            scene.next_command
          end
        else
          @wait += 1
          if @wait > timeout_frames
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
      def apply_spec(proxy, kind, obj_id, tgt, requester_id)
        act = proxy.input
        return if act.nil?
        case kind
        when 'g' then act.set_guard
        when 's' then act.set_skill(obj_id)
        when 'i' then act.set_item(obj_id)
        else          act.set_attack
        end
        resolve_target(act, tgt, requester_id)
        if act.item.nil?
          act.set_attack
          act.target_index = first_alive_enemy_index || 0
        end
      end

      # Map the wire target onto a host-local index. Enemy: the troop index is already
      # host-local (identical troop). Ally: look the (owner, actor_id) up in the host's
      # OWN battle_members order ('self' = the requesting guest's proxy); a raw index would
      # land on the wrong ally since the combined party is ordered differently per peer.
      def resolve_target(act, tgt, requester_id)
        return if tgt.nil?
        if tgt.start_with?('e:')
          act.target_index = tgt[2..-1].to_i
        elsif tgt.start_with?('f:')
          body = tgt[2..-1]
          dot  = body.rindex('.')
          return if dot.nil?
          idx = host_friend_index(body[0...dot], body[dot + 1..-1].to_i, requester_id)
          act.target_index = idx if idx
        end
      end

      def host_friend_index(owner_s, actor_id, requester_id)
        owner   = (owner_s == 'self') ? requester_id : owner_s.to_i
        host_id = $bsmp_server ? $bsmp_server.server_user_id : nil
        $game_party.battle_members.each_with_index do |a, i|
          if a.is_a?(Game_BSMPProxyActor)
            return i if a.bsmp_owner == owner and a.id == actor_id
          else
            return i if owner == host_id and a.id == actor_id
          end
        end
        nil
      end

      # A skill/item tagged as "no turn consumption" (HZM QuickSkill, script 158). We
      # inject actions straight onto proxy.input, bypassing the item/skill window where
      # 158 records @hzm_vxa_quickSkill_skill — so we re-set it before resuming (host_tick)
      # to keep the quick (instant, free-action) behaviour the local player gets.
      def quick_item?(item)
        return false if item.nil?
        return false unless defined?(HZM_VXA::QuickSkill)
        return false unless item.respond_to?(:hzm_vxa_note_match)
        item.hzm_vxa_note_match(HZM_VXA::QuickSkill::QUICK_KEYS) ? true : false
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

      # --- guest side (6.4.1) -------------------------------------------------

      attr_reader :guest_actor

      def guest_active?
        not @guest_actor.nil?
      end

      def guest_begin(actor)
        @guest_actor = actor
      end

      def guest_end
        @guest_actor = nil
      end

      # Serialize the actor's chosen action (built by the reused command UI) into the wire
      # spec and send it to the host. Kind is derived from the action's item: a plain
      # attack / guard map to their skill ids, a real skill is 's', an item is 'i'.
      def guest_send(actor)
        act = actor.input
        kind = 'a'; obj = 0; tgt = "n"
        if act
          it = act.item
          if it.nil?
            kind = 'a'
          elsif it.is_a?(RPG::Item)
            kind = 'i'; obj = it.id
          elsif it.id == actor.guard_skill_id
            kind = 'g'
          elsif it.id == actor.attack_skill_id
            kind = 'a'
          else
            kind = 's'; obj = it.id
          end
          tgt = encode_target(act)
        end
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_INPUT, 0,
          "#{actor.id};#{kind};#{obj};#{tgt}"))
      end

      # Encode the action's target for the wire. Enemy targets ride a troop index (the
      # troop is identical on every peer). Ally targets must NOT ride a raw index — the
      # combined party is in a DIFFERENT order on each peer — so send the ally's identity
      # (owner, actor_id); for our OWN actor we don't know our steam id, so send 'self'
      # and let the host resolve it to our proxy (the requester). 'n' = no selection
      # (all/self/none scope) — the host resolves it by the action's scope.
      def encode_target(act)
        it = act.item
        return "n" if it.nil? or not it.need_selection? # need_selection?/for_* live on the item
        if it.for_opponent?
          "e:#{act.target_index}"
        else
          ally = $game_party.battle_members[act.target_index]
          return "n" if ally.nil?
          owner = ally.is_a?(Game_BSMPProxyActor) ? ally.bsmp_owner.to_s : "self"
          "f:#{owner}.#{ally.id}"
        end
      end
    end

    reset
  end

  module Events
    # Non-owner: the battle owner wants this actor's command. Open the real command UI
    # on our actor (6.4.1). Point-to-point, so receiving it means it's for one of our
    # actors. Ignore a request that arrives while we're already choosing (single
    # command at a time).
    def self.on_battle_input_request(packet)
      return if BSMP::Battle.host_session?  # the battle host doesn't get requests
      return if not BSMP::Battle.client_session?
      return if BSMP::BattleInput.guest_active?
      actor_id = packet.data.to_i
      actor = $game_party.battle_members.find do |a|
        (not a.is_a?(Game_BSMPProxyActor)) and a.id == actor_id
      end
      return if actor.nil?
      scene = SceneManager.scene
      return unless scene.is_a?(Scene_Battle)
      scene.bsmp_guest_start_input(actor)
    end

    # Owner-of-battle: a guest replied with its command — hand it to BattleInput to
    # inject + resume. (Battle owner = map owner; we keep the same host?/map_owner
    # semantics, but the guard is explicit so it stays correct when the lobby host is
    # itself a mute client on a guest-owned map.)
    def self.on_battle_input(packet)
      return if not BSMP.host?
      BSMP::BattleInput.on_reply(packet.from_id, packet.data)
    end

    HANDLERS[BATTLE_INPUT_REQUEST] = method(:on_battle_input_request)
    HANDLERS[BATTLE_INPUT]         = method(:on_battle_input)
  end
end

#==============================================================================
# ■ Scene_Battle — host parks proxy turns; guest drives the real command UI
#==============================================================================
class Scene_Battle
  # Fresh battle: clear any parked/active input from a previous fight (e.g. an F12 unwind).
  alias bsmp_input_scene_start start
  def start
    BSMP::BattleInput.reset
    bsmp_input_scene_start
  end

  # A battler reached its ATB turn. For a guest's proxy on the HOST, don't open a local
  # window — request the command from its owner and park (BattleInput). The host's own
  # actors and any non-co-op battle take the normal path. (On a guest this is reused to
  # open the command window for our own actor, where host_session? is false.)
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

  # --- guest remote-input (6.4.1) -----------------------------------------

  # Guest: the host asked for this actor's command. Reuse the game's own command flow —
  # point BattleManager at our actor and open the actor command window. The stock handlers
  # (command_attack/skill/guard/item + target windows) build a Game_Action on actor.input;
  # they all funnel through next_command, which we intercept below to send instead of
  # advancing. The mute scene's update pumps the windows (update_all_windows via super).
  def bsmp_guest_start_input(actor)
    actor.instance_variable_set(:@action_input_index, 0) # input = @actions[0]; never stale
    actor.make_actions
    if actor.input.nil?
      # Not commandable (e.g. unmovable) — answer with a plain attack so the host resumes.
      BSMP::BattleInput.guest_begin(actor)
      BSMP::BattleInput.guest_send(actor)
      BSMP::BattleInput.guest_end
      return
    end
    idx = $game_party.battle_members.index(actor)
    BattleManager.instance_variable_set(:@actor_index, idx) if idx
    BSMP::BattleInput.guest_begin(actor)
    start_actor_command_selection
  end

  # Tear down the command/target windows after we've answered.
  def bsmp_guest_finish_input
    @actor_command_window.close if @actor_command_window
    @party_command_window.close if @party_command_window
    @skill_window.hide          if @skill_window
    @item_window.hide           if @item_window
    @enemy_window.hide          if @enemy_window
    @actor_window.hide          if @actor_window
    @status_window.unselect     if @status_window
  end

  # The single command+target funnel. While we're answering a remote request, capture the
  # chosen action and ship it instead of advancing the (non-running) local turn.
  alias bsmp_input_next_command next_command
  def next_command
    if BSMP::BattleInput.guest_active?
      actor = BSMP::BattleInput.guest_actor
      BSMP::BattleInput.guest_send(actor)
      BSMP::BattleInput.guest_end
      bsmp_guest_finish_input
    else
      bsmp_input_next_command
    end
  end

  # Escape from the guest's command window must NOT run locally (that would flee only the
  # guest's mute battle and leave the host parked until it times out). Send a flee intent;
  # the host runs the authoritative escape roll (see on_reply / host_tick).
  alias bsmp_input_command_escape command_escape
  def command_escape
    if BSMP::BattleInput.guest_active?
      actor = BSMP::BattleInput.guest_actor
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_INPUT, 0, "#{actor.id};e;0;0"))
      BSMP::BattleInput.guest_end
      bsmp_guest_finish_input
    else
      bsmp_input_command_escape
    end
  end

  # Cancel from the top command window has nowhere to go back to on a guest (no party
  # command / no prior actor in our local flow) — just keep the command window up.
  alias bsmp_input_prior_command prior_command
  def prior_command
    if BSMP::BattleInput.guest_active?
      @actor_command_window.activate if @actor_command_window
    else
      bsmp_input_prior_command
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-BattleInput"]
