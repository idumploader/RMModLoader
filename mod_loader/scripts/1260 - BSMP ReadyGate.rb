#==============================================================================
# BSMP ReadyGate — consensus gate for "all players must confirm to continue" map
# events (step 6.7). A boss fog, an NG+ stone, a point-of-no-return door — any map
# event whose page runs the Script call:
#
#     bsmp_ready_gate            # gate id defaults to this map+event
#     bsmp_ready_gate("boss_x")  # or an explicit shared id
#
# The acting player PARKS there (their event is running, so they can't move) showing
# "Waiting for party  k/N"; everyone else keeps playing freely until they too walk up
# and interact. When EVERY player has confirmed the same gate, all the parked events
# resume and run the rest of the page (start the boss, kick off NG+, open the door).
# Pressing the cancel button while waiting backs out (the event exits, no payoff).
#
# The host is the single tally authority: peers send READY_GATE, the host counts the
# distinct players per gate and broadcasts READY_GATE_SYNC (count/need/done). "need"
# is the live lobby size, so a disconnect mid-wait lowers the bar instead of hanging.
# Solo / offline: no gate, the call returns at once and the event just continues.
#
# Loads after BSMP core/UI (packets, Progress_Window). Different mechanic from a
# synchronized dialogue VOTE (choosing between options) — that's a separate feature.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-ReadyGate"]
$imported["IDL-BSMP-ReadyGate"] = "1.0"

if defined?(BSMP)

module BSMP
  # After a gate opens, EVERY peer resumes its copy of the event — but a battle payoff
  # must fire on only ONE peer. co-op battles are host-authoritative (the host runs the
  # real Scene_Battle; everyone else joins via BATTLE_START), so the leader is the host.
  # Used to skip the body on non-leaders for an auto-gated battle event; also usable
  # manually as a Conditional Branch condition around a hand-placed Battle Processing.
  # Solo / offline -> true (you run it).
  def self.gate_leader?
    return true unless bsmp_network_running?
    BSMP.host?
  end

  # The shared gate id for a configured gate event, or nil. Config::READY_GATE_EVENTS
  # is { map_id => [entry, ...] } where an entry is a bare event_id (its own gate) or
  # an ARRAY of event_ids that share ONE gate — e.g. the several tiles of a single fog
  # wall, so confirming any tile counts toward the same consensus.
  def self.ready_gate_id(map_id, event_id)
    entries = Config::READY_GATE_EVENTS[map_id]
    return nil unless entries
    entries.each do |e|
      if e.is_a?(Array)
        return "#{map_id}:g#{e.min}" if e.include?(event_id)
      elsif e == event_id
        return "#{map_id}:#{event_id}"
      end
    end
    nil
  end

  module ReadyGate
    class << self
      def reset
        @host_sets = {}  # host only: gate_id => [player_id, ...] currently confirmed
        @progress  = {}  # everyone: gate_id => { :count, :need, :done }
        @completed = {}  # everyone: gate_id => true, gates already passed THIS map visit
      end

      # A gate that reached consensus stays "passed" for the whole map visit, so a
      # multi-tile fog wall (whose other tiles fade but stay touch-triggerable) can't
      # re-fire as you walk through — which the others, already through, would not
      # rejoin (hang). Re-armed when you leave and re-enter the map (reset_map below);
      # to re-test, step off the map and back.
      def completed?(gate_id)
        @completed[gate_id] ? true : false
      end

      def mark_completed(gate_id)
        @completed[gate_id] = true
      end

      # New map: re-arm every gate and drop stale tally / progress.
      def reset_map
        @host_sets = {}
        @progress  = {}
        @completed = {}
      end

      # --- caller side (bsmp_ready_gate) --------------------------------------

      # Register us as confirmed for this gate. On the host we tally directly; on a
      # guest we tell the host, which stamps our id (we don't know our own) and tallies.
      def signal(gate_id)
        if BSMP.host?
          host_add(gate_id, $bsmp_server.server_user_id)
        else
          bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::READY_GATE, 0, gate_id.to_s))
        end
      end

      # Back out of a gate we were waiting on.
      def cancel(gate_id)
        if BSMP.host?
          host_remove(gate_id, $bsmp_server.server_user_id)
        else
          bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::READY_GATE_CANCEL, 0, gate_id.to_s))
        end
      end

      def done?(gate_id)
        p = @progress[gate_id]
        p ? p[:done] : false
      end

      def text(gate_id)
        p = @progress[gate_id] || { :count => 0, :need => 0 }
        n = [p[:count], p[:need]].min  # ghost ids can't show more than "all"
        BSMP.t("bsmp.ready_gate_wait") % [n, p[:need]]
      end

      def ratio(gate_id)
        p = @progress[gate_id]
        return 0.0 if p.nil? or p[:need].to_i <= 0
        [p[:count].to_f / p[:need], 1.0].min
      end

      def clear(gate_id)
        @progress.delete(gate_id)
      end

      # --- host tally ---------------------------------------------------------

      def host_add(gate_id, pid)
        set = (@host_sets[gate_id] ||= [])
        set << pid unless set.include?(pid)
        host_broadcast(gate_id)
      end

      def host_remove(gate_id, pid)
        set = @host_sets[gate_id]
        return if set.nil?
        set.delete(pid)
        host_broadcast(gate_id)
      end

      # Recount and tell everyone. need = live lobby size, so a mid-wait disconnect
      # lowers the bar. On completion the set is consumed so the gate can run again.
      def host_broadcast(gate_id)
        set  = @host_sets[gate_id] || []
        need = BSMP.battle_player_count
        done = set.size >= need
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::READY_GATE_SYNC, 0,
          "#{gate_id};#{set.size};#{need};#{done ? 1 : 0}"))
        apply_sync(gate_id, set.size, need, done)  # host applies to its own view too
        @host_sets.delete(gate_id) if done
      end

      # --- everyone: receive the tally ----------------------------------------

      def apply_sync(gate_id, count, need, done)
        @progress[gate_id] = { :count => count, :need => need, :done => done }
      end
    end

    reset
  end

  module Events
    def self.on_ready_gate(packet)
      return unless BSMP.host?
      BSMP::ReadyGate.host_add(packet.data.to_s, packet.from_id)
    end

    def self.on_ready_gate_cancel(packet)
      return unless BSMP.host?
      BSMP::ReadyGate.host_remove(packet.data.to_s, packet.from_id)
    end

    def self.on_ready_gate_sync(packet)
      return if BSMP.host?  # the host already applied its own tally locally
      g, c, n, d = packet.data.to_s.split(';')
      BSMP::ReadyGate.apply_sync(g, c.to_i, n.to_i, d.to_i != 0)
    end

    HANDLERS[READY_GATE]        = method(:on_ready_gate)
    HANDLERS[READY_GATE_CANCEL] = method(:on_ready_gate_cancel)
    HANDLERS[READY_GATE_SYNC]   = method(:on_ready_gate_sync)
  end
end

#==============================================================================
# ■ Game_Interpreter — the bsmp_ready_gate Script call (parks the acting player)
#==============================================================================
class Game_Interpreter
  # Park here until every player has confirmed the same gate. Solo / offline returns
  # at once (the event just continues). gate_id must be identical on every peer for
  # the SAME gate — the default (map:event) is, since it's the same event on each
  # peer's copy of the map. Cancel button = back out (the event exits, no payoff).
  # Returns true if consensus was reached (run the rest of the page) or there was no
  # gate to wait on (solo / lost session); false if the player cancelled (the event was
  # already aborted via command_115, so the caller must not run the gated payload).
  def bsmp_ready_gate(gate_id = nil)
    return true unless bsmp_network_running?  # solo: no gate, run the rest of the page
    gate_id = (gate_id || "#{@map_id}:#{@event_id}").to_s
    BSMP::ReadyGate.clear(gate_id)
    BSMP::ReadyGate.signal(gate_id)
    win = BSMP::Progress_Window.new
    loop do
      unless bsmp_network_running?  # lost the session mid-wait -> proceed (now solo)
        win.dispose
        return true
      end
      win.text     = BSMP::ReadyGate.text(gate_id)
      win.progress = BSMP::ReadyGate.ratio(gate_id)
      win.update
      break if BSMP::ReadyGate.done?(gate_id)
      if Input.trigger?(:B)  # cancel: leave the gate, abort the event (no payoff)
        BSMP::ReadyGate.cancel(gate_id)
        win.dispose
        command_115
        return false
      end
      Fiber.yield
    end
    win.dispose
    BSMP::ReadyGate.mark_completed(gate_id)  # consensus reached: don't re-fire this wall
    BSMP::ReadyGate.clear(gate_id)
    true
  end

  # --- auto-gate configured events (no map editing) ---------------------------
  # Flag this interpreter when it's running a configured gate event whose active page
  # is PLAYER-TRIGGERED (action / player-touch / event-touch — something you walk up
  # to and activate). Autorun/parallel pages are NOT gated: they aren't "all players
  # press" events, and a world-owned one is suppressed on guests so the host would
  # wait forever. Covers boss fogs AND non-battle "all confirm" events (NG+ stone).
  alias bsmp_gate_setup setup
  def setup(*args)
    bsmp_gate_setup(*args)
    @bsmp_gate_id = nil
    @bsmp_kill_gated = false  # re-arm the kill-choice consensus gate for this event run
    ev = args[1].to_i
    return unless ev > 0 and $game_map
    gid = BSMP.ready_gate_id(@map_id, ev)
    return unless gid
    return if BSMP::ReadyGate.completed?(gid)  # wall already passed this map visit
    e = $game_map.events[ev]
    trig = e ? e.instance_variable_get(:@trigger) : nil
    @bsmp_gate_id = gid if trig and trig <= 2  # 0 action / 1,2 touch (not autorun/parallel)
  end

  # Park at the gate before running a flagged event's body. After consensus EVERY peer
  # runs the full body (open the fog, transfer into the arena, NG+ locally, ...). A
  # battle inside is deduped by the normal host-authority path: the host runs the real
  # fight, guests' command_301 joins via BATTLE_START (on_battle_request ignores the
  # redundant requests once the host's session is live).
  alias bsmp_gate_run run
  def run
    if @bsmp_gate_id
      gid = @bsmp_gate_id
      @bsmp_gate_id = nil
      bsmp_ready_gate(gid)
    end
    bsmp_gate_run
  end
end

#==============================================================================
# ■ Game_Interpreter — consensus gate on an irreversible removal choice
#==============================================================================
# Killing/imprisoning a covenant NPC is permanent shared world state (the 杀害/监禁
# switches remove them for everyone). So one player shouldn't do it alone. We gate on the
# SELECTED option (command_402 "When [choice]"), NOT on the menu appearing — a mixed menu
# like ["Ничего не делать", "Изнасиловать", "Убить"] must only gate when the player
# actually picks a removal option, never on "do nothing". The acting player parks at a
# ready gate until EVERY player has reached the SAME NPC and picked the SAME deed; a
# holdout never arrives -> no removal, and the actor can cancel (B) to back out. The gate
# is keyed by the chosen deed (c<index> of Config::CHOICE_GATE_WORDS) so kill vs imprison
# need separate consensus. No new packets/UI — reuses bsmp_ready_gate; the co-op battle
# that follows is deduped by host authority, then transfer-follow pulls everyone to the
# scene. Dissent is passive (not coming = veto); fine for a rare, momentous action.
class Game_Interpreter
  alias bsmp_killgate_command_402 command_402
  def command_402
    # @branch[@indent] == @params[0] => this is the SELECTED When-branch (stock's own
    # test); @params[1] is its choice text. Only the picked option can open the gate.
    if not @bsmp_kill_gated and bsmp_network_running? and @branch[@indent] == @params[0]
      key = bsmp_gate_choice_key(@params[1])
      if key
        @bsmp_kill_gated = true
        # False = cancelled; bsmp_ready_gate already aborted the event (command_115),
        # so don't run the picked branch's body (the kill/imprison sequence).
        return unless bsmp_ready_gate("#{@map_id}:#{@event_id}:#{key}")
      end
    end
    bsmp_killgate_command_402
  end

  # ASCII gate key "c<index>" for a choice text matching Config::CHOICE_GATE_WORDS (exact,
  # colour codes + trailing punctuation stripped), or nil. The index keeps the wire key
  # ASCII (no Cyrillic/CJK in packet gate-ids) and distinguishes deeds; identical choice
  # text on every peer's copy of the data yields the same index, so the gate aligns.
  # Normalise a choice's text for matching: drop escape codes (\c[2] / \\c[2], 1+
  # backslashes), any stray backslashes, trim, downcase, strip trailing punctuation.
  # Ruby 1.9.2 String#downcase is ASCII-only (won't lower "Изнасиловать"->"изнасиловать"),
  # so fold Cyrillic ourselves with tr before the ASCII downcase. Keep CHOICE_GATE_WORDS
  # lowercase.
  CYR_UP = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
  CYR_LO = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
  def bsmp_choice_clean(text)
    text.to_s.gsub(/\\+[A-Za-z]\[\d+\]/, "").gsub(/\\+/, "").strip.
      tr(CYR_UP, CYR_LO).downcase.sub(/[?!.。！？…]+\z/, "")
  end

  def bsmp_gate_choice_key(text)
    words = BSMP::Config::CHOICE_GATE_WORDS
    return nil if words.nil? or words.empty?
    i = words.index(bsmp_choice_clean(text))
    i ? "c#{i}" : nil
  end
end

#==============================================================================
# ■ Game_Map — re-arm consensus gates on map change
#==============================================================================
class Game_Map
  # A passed gate is remembered only for the current map visit (so a faded fog wall
  # can't re-fire mid-visit). Entering any map clears that, so the wall works again.
  alias bsmp_gate_map_setup setup
  def setup(map_id)
    bsmp_gate_map_setup(map_id)
    BSMP::ReadyGate.reset_map
  end
end

#==============================================================================
# ■ DataManager — re-arm gates on save load / new game
#==============================================================================
# Loading a save restores $game_map straight from Marshal WITHOUT calling
# Game_Map#setup, so the map hook above never fires and a gate passed before the
# save would stay "passed" in our runtime memory. Clear it here too.
module DataManager
  class << self
    alias bsmp_gate_load_game load_game
    def load_game(index)
      result = bsmp_gate_load_game(index)
      BSMP::ReadyGate.reset_map if result
      result
    end

    alias bsmp_gate_setup_new_game setup_new_game
    def setup_new_game
      bsmp_gate_setup_new_game
      BSMP::ReadyGate.reset_map
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-ReadyGate"]
