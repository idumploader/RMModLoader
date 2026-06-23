#==============================================================================
# BSMP Battle Messages — sync in-battle troop dialogue + an all-confirm barrier
# (step 6.8).
#
# Troop-event ShowText runs ONLY on the battle host: guests are mute clients that
# never execute troop events, so boss banter / story lines mid-fight never appeared
# for them. The host mirrors each battle dialogue to the guests' $game_message
# (BATTLE_MSG_SHOW), and the message does not close on anyone until EVERY player has
# pressed to dismiss it (BATTLE_MSG_ACK / BATTLE_MSG_CLOSE, host = tally authority).
#
# Scope: only troop-event ShowText (Game_Interpreter#command_101 while in battle) is
# mirrored — flagged on the host via $game_temp.bsmp_dialogue_pending, consumed when
# the message starts (Window_Message#update_fiber). System messages from BattleManager
# ("appeared", "victory / gold") are NOT mirrored here: they carry no seq and so skip
# the barrier and show locally as before. Each peer derives them from the identical
# troop, so they already match.
#
# The barrier is keyed by the host-assigned seq (identical on every peer), so there is
# no fragile per-page counter to drift. A timeout un-pauses anyway if a peer never acks
# (disconnect / a message a peer didn't reproduce), so the battle can't deadlock.
#
# Loads after BSMP core/battle/UI. No-op when not networked or outside a co-op battle.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-BattleMessages"]
$imported["IDL-BSMP-BattleMessages"] = "1.0"

if defined?(BSMP)

# Unit separator: a byte that never appears in display text, so it safely delimits the
# wire payload (face name, the message lines, ...).
BSMP_MSG_US = "\x1f" unless defined?(BSMP_MSG_US)

module BSMP
  module BattleMsg
    # How long (frames) a peer waits at a dismissed dialogue for the all-confirm before
    # giving up and proceeding alone. Guards against a peer that never acks (it left, or
    # never reproduced this exact message). ~12 s at 60 fps.
    BARRIER_TIMEOUT = 720

    class << self
      # result_phase (host): we're inside process_victory/defeat/escape, so mirror those
      # system messages too (they don't go through command_101). suppress_local (guest):
      # we're replaying the result for control flow only — drop its local $game_message
      # lines, since the host already mirrored them during the mute battle.
      attr_accessor :result_phase, :suppress_local

      def reset
        @seq      = 0     # host: monotonic dialogue id
        @acks     = {}    # host: seq => [player_id, ...] that dismissed it
        @closed   = {}    # everyone: seq => true once the gate opened
        @pending  = []    # guest: received shows not yet applied (window was busy)
        @result_phase   = false
        @suppress_local = false
      end

      # True while we should be syncing/gating battle messages: networked and inside a
      # co-op battle session (host streaming, or a mute guest joined to one).
      def gated?
        return false unless bsmp_network_running?
        BSMP::Battle.host_session? or BSMP::Battle.client_session?
      end

      # Host, actively streaming a co-op battle — the only peer that mirrors dialogue.
      def host_broadcasting?
        bsmp_network_running? and BSMP.host? and BSMP::Battle.host_session?
      end

      # --- host: capture a starting dialogue and push it to the guests ----------
      # Called once, when the message window starts a message flagged as troop dialogue
      # (see Window_Message#update_fiber). $game_message is fully built by now (command_101
      # added all its lines before wait_for_message). Stamps it with a fresh seq so the
      # barrier below can match it across peers.
      def broadcast_show
        @seq += 1
        seq = @seq.to_s
        $game_message.bsmp_msg_seq = seq
        m = $game_message
        fields = [seq, m.face_name.to_s, m.face_index.to_i.to_s,
                  m.background.to_i.to_s, m.position.to_i.to_s] + m.texts.map { |t| t.to_s }
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_MSG_SHOW, 0,
          fields.join(BSMP_MSG_US)))
      end

      # --- guest: receive a dialogue and show it --------------------------------
      # Apply now if the message window is free, else queue (drained in try_drain when the
      # previous mirrored line finishes). Marks $game_message with the same seq so the
      # guest's input_pause joins the same barrier.
      def enqueue_show(data)
        @pending ||= []
        @pending << data
        try_drain
      end

      def try_drain
        @pending ||= []
        @pending.clear unless gated?   # drop anything left over from a previous battle
        return if @pending.empty?
        return if $game_message.busy? or $game_message.visible
        apply(@pending.shift)
      end

      def apply(data)
        # data is already UTF-8 (Events.on_packet re-tags every payload), so a multibyte
        # face/name reaches $game_message intact instead of crashing Cache later.
        f = data.to_s.split(BSMP_MSG_US, -1)
        return if f.size < 5
        $game_message.clear
        $game_message.face_name  = f[1]
        $game_message.face_index = f[2].to_i
        $game_message.background  = f[3].to_i
        $game_message.position    = f[4].to_i
        f[5..-1].each { |line| $game_message.add(line) }
        $game_message.bsmp_msg_seq = f[0]
      end

      # --- the all-confirm barrier (called from Window_Message#input_pause) ------
      # The local player already pressed to dismiss; register that and park (yielding the
      # message fiber so frames pass and the net pump runs) until the host says everyone
      # is done — or the timeout fires. Shows a "Waiting for other players..." plate, but
      # only if we actually have to wait (no flash when everyone's already ready).
      def wait_consensus(seq)
        return if seq.nil?
        seq = seq.to_s
        signal(seq)
        win = nil
        t = 0
        begin
          until closed?(seq)
            break unless gated?            # lost the session mid-wait -> just proceed
            if win.nil?
              win = BSMP::Progress_Window.new
              win.text = BSMP.t("bsmp.battle_wait_others")
              win.progress = 1.0           # indeterminate; we don't tally per-peer here
              win.z = 300                   # above the message window (z 200)
            end
            win.update
            t += 1
            break if t > BARRIER_TIMEOUT   # a peer never acked -> don't deadlock the fight
            Fiber.yield
          end
        ensure
          win.dispose if win
        end
      end

      # Register us as having dismissed this dialogue. Host tallies directly; a guest
      # tells the host (which stamps the sender id — a guest doesn't know its own).
      def signal(seq)
        if BSMP.host?
          host_add(seq, ($bsmp_server ? $bsmp_server.server_user_id : 0))
        else
          bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_MSG_ACK, 0, seq.to_s))
        end
      end

      # Host tally. need = live battle lobby size, so a disconnect lowers the bar instead
      # of hanging. On all-confirmed, open the gate for everyone.
      def host_add(seq, pid)
        seq = seq.to_s
        return if @closed[seq]
        s = (@acks[seq] ||= [])
        s << pid unless s.include?(pid)
        broadcast_close(seq) if s.size >= BSMP.battle_player_count
      end

      def broadcast_close(seq)
        seq = seq.to_s
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_MSG_CLOSE, 0, seq))
        mark_closed(seq)
        @acks.delete(seq)
      end

      def mark_closed(seq)
        @closed ||= {}
        @closed[seq.to_s] = true
        # Keep the dict from growing unbounded across a long session of battles.
        @closed.clear if @closed.size > 256
      end

      def closed?(seq)
        @closed ||= {}
        @closed[seq.to_s] ? true : false
      end

      # --- battle-log line mirror -----------------------------------------------
      # The mute guest runs no actions, so its Window_BattleLog ("X strikes!", damage
      # lines) stayed blank. The host mirrors each log mutation; the guest replays it on
      # its own log window (noted on creation). Drawing from the packet handler is fine —
      # the window's bitmap is redrawn anyway.
      def note_log_window(win)
        @log_window = win
      end

      def broadcast_log(op, arg = "")
        return unless host_broadcasting?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::BATTLE_LOG, 0,
          "#{op}#{BSMP_MSG_US}#{arg}"))
      end

      def apply_log(data)
        return unless BSMP::Battle.client_session?
        w = @log_window
        return if w.nil? or w.disposed?
        op, arg = data.to_s.split(BSMP_MSG_US, 2)
        case op
        when "a" then w.add_text(arg.to_s)
        when "r" then w.replace_text(arg.to_s)
        when "c" then w.clear
        when "b" then w.back_to(arg.to_i)
        when "1" then w.back_one
        end
      end
    end

    reset
  end

  module Events
    # Host pushed a battle dialogue: show it in our $game_message (the mute scene's
    # message window renders it like any other). Ignore our own echo.
    def self.on_battle_msg_show(packet)
      return if BSMP::Battle.host_session?
      return unless BSMP::Battle.client_session?
      BSMP::BattleMsg.enqueue_show(packet.data)
    end

    # A peer dismissed a dialogue: host counts it toward that seq's consensus.
    def self.on_battle_msg_ack(packet)
      return unless BSMP.host?
      BSMP::BattleMsg.host_add(packet.data.to_s, packet.from_id)
    end

    # The gate opened: stop waiting and let the message close.
    def self.on_battle_msg_close(packet)
      return if BSMP.host?  # the host already marked it closed when it broadcast
      BSMP::BattleMsg.mark_closed(packet.data.to_s)
    end

    # Host mirrored a battle-log line: replay it on our log window.
    def self.on_battle_log(packet)
      return if BSMP::Battle.host_session?
      BSMP::BattleMsg.apply_log(packet.data)
    end

    HANDLERS[BATTLE_MSG_SHOW]  = method(:on_battle_msg_show)
    HANDLERS[BATTLE_MSG_ACK]   = method(:on_battle_msg_ack)
    HANDLERS[BATTLE_MSG_CLOSE] = method(:on_battle_msg_close)
    HANDLERS[BATTLE_LOG]       = method(:on_battle_log)
  end
end

#==============================================================================
# ■ Game_Message — carry the co-op dialogue seq (set => this message is gated)
#==============================================================================
class Game_Message
  attr_accessor :bsmp_msg_seq

  # clear() runs at the start of every message; drop the seq so a following non-dialogue
  # (system) message isn't mistaken for a gated one.
  alias bsmp_msg_clear clear
  def clear
    bsmp_msg_clear
    @bsmp_msg_seq = nil
  end

  # While the guest replays the battle result for control flow only (client_battle_return),
  # drop its locally-generated lines — the host already mirrored them with the barrier.
  alias bsmp_msg_add add
  def add(text)
    return if defined?(BSMP::BattleMsg) and BSMP::BattleMsg.suppress_local
    bsmp_msg_add(text)
  end
end

#==============================================================================
# ■ Game_Temp — flag set while the troop interpreter is opening a dialogue
#==============================================================================
class Game_Temp
  attr_accessor :bsmp_dialogue_pending
end

#==============================================================================
# ■ Game_Interpreter — flag battle ShowText so only troop dialogue is mirrored
#==============================================================================
class Game_Interpreter
  # Stock command_101 builds $game_message and then blocks in wait_for_message until the
  # message is dismissed — too late to capture afterwards. Instead flag it here; the flag
  # is consumed the moment the message window starts the message (update_fiber below),
  # which happens inside that wait. Only battle ShowText on the streaming host is flagged,
  # so BattleManager's own "appeared/victory" messages (no command_101) aren't mirrored.
  alias bsmp_msg_command_101 command_101
  def command_101(*args)
    if $game_party.in_battle and BSMP::BattleMsg.host_broadcasting?
      $game_temp.bsmp_dialogue_pending = true
    end
    bsmp_msg_command_101(*args)
  end
end

#==============================================================================
# ■ Window_Message — broadcast on message start (host) + the all-confirm barrier
#==============================================================================
class Window_Message < Window_Base
  # A message is about to start (fiber created). On the host, if it was flagged as troop
  # dialogue, mirror it now ($game_message is fully built). On the guest, drain any queued
  # mirrored dialogue into the idle window so it shows.
  alias bsmp_msg_update_fiber update_fiber
  def update_fiber
    if @fiber.nil? and !$game_message.scroll_mode
      # Mirror a starting host message when it's a troop dialogue (command_101 flagged it)
      # OR a result-phase system message (victory/defeat lines — they bypass command_101).
      # Emerge is NOT mirrored: it's shown locally on the guest (different code path), so
      # mirroring it too would double it.
      if BSMP::BattleMsg.host_broadcasting? and $game_message.busy? and
         ($game_temp.bsmp_dialogue_pending or BSMP::BattleMsg.result_phase)
        $game_temp.bsmp_dialogue_pending = false
        BSMP::BattleMsg.broadcast_show
      elsif BSMP::Battle.client_session? and !$game_message.busy?
        BSMP::BattleMsg.try_drain
      end
    end
    bsmp_msg_update_fiber
  end

  # The per-page "press to continue" wait. For a co-op dialogue (seq stamped), after the
  # local press, hold the page open until EVERY player has also pressed (or the timeout).
  # Non-dialogue messages keep the stock behaviour untouched.
  alias bsmp_msg_input_pause input_pause
  def input_pause
    seq = $game_message.bsmp_msg_seq
    if seq and BSMP::BattleMsg.gated?
      self.pause = true
      wait(10)
      Fiber.yield until Input.trigger?(:B) || Input.trigger?(:C)
      Input.update
      BSMP::BattleMsg.wait_consensus(seq)
      self.pause = false
    else
      bsmp_msg_input_pause
    end
  end
end

#==============================================================================
# ■ M_SKIP — don't let CTRL message-skip bypass the co-op all-confirm barrier
#==============================================================================
# Script 238's message-skip sets @pause_skip while CTRL is held, which makes the message
# processor skip input_pause ENTIRELY — so a gated battle dialogue gets blown past without
# the barrier (no ack), desyncing the turn flow (the guest's command window never opened).
# Suppress skip only while a gated co-op message (seq stamped) is active; normal messages
# keep skip. Guarded so a game without script 238 just skips this.
if defined?(M_SKIP)
  module M_SKIP
    class << self
      alias bsmp_orig_seal seal
      def seal
        if $game_message and $game_message.bsmp_msg_seq and BSMP::BattleMsg.gated?
          return false
        end
        bsmp_orig_seal
      end
    end
  end
end

#==============================================================================
# ■ Window_BattleLog — host mirrors every log mutation to the guests
#==============================================================================
# The action messages ("X strikes!", damage lines) are built only on the host (the mute
# guest runs no actions). The host broadcasts each mutation; the guest replays it on its
# own log window. The guest notes its window on creation so the handler can reach it.
class Window_BattleLog
  alias bsmp_log_initialize initialize
  def initialize(*args)
    bsmp_log_initialize(*args)
    BSMP::BattleMsg.note_log_window(self)
  end

  alias bsmp_log_add_text add_text
  def add_text(text)
    BSMP::BattleMsg.broadcast_log("a", text.to_s)
    bsmp_log_add_text(text)
  end

  alias bsmp_log_replace_text replace_text
  def replace_text(text)
    BSMP::BattleMsg.broadcast_log("r", text.to_s)
    bsmp_log_replace_text(text)
  end

  alias bsmp_log_clear clear
  def clear
    BSMP::BattleMsg.broadcast_log("c")
    bsmp_log_clear
  end

  alias bsmp_log_back_to back_to
  def back_to(line_number)
    BSMP::BattleMsg.broadcast_log("b", line_number.to_s)
    bsmp_log_back_to(line_number)
  end

  alias bsmp_log_back_one back_one
  def back_one
    BSMP::BattleMsg.broadcast_log("1")
    bsmp_log_back_one
  end
end

#==============================================================================
# ■ Scene_Battle — reopen the mute guest's status/ally HUD after a dialogue
#==============================================================================
# Stock update_message_open closes the battle status window while a message is busy.
# On the host the turn flow (start_party_command_selection) reopens it afterwards, but
# the mute guest never runs that flow — so once a mirrored dialogue closed the HUD, the
# ally/party window stayed gone. Reopen it ourselves when the dialogue is done.
class Scene_Battle
  alias bsmp_msg_update_message_open update_message_open
  def update_message_open
    bsmp_msg_update_message_open
    if BSMP::Battle.client_session? and @status_window and
       !$game_message.busy? and @status_window.close?
      @status_window.open
    end
  end
end

#==============================================================================
# ■ BattleManager — re-arm the message barrier at the start of every battle
#==============================================================================
# setup -> init_members runs on the host (real battle) and on a guest's mute scene
# (bsmp_enter_pending_battle also calls BattleManager.setup), so this clears stale
# tally / queued shows from the previous fight on both sides.
module BattleManager
  class << self
    alias bsmp_msg_init_members init_members
    def init_members
      bsmp_msg_init_members
      BSMP::BattleMsg.reset
    end

    # The result messages (victory / defeat / escape) go straight to $game_message, not
    # through command_101, so flag the result phase: while it's set, the host mirrors those
    # messages to the guests (update_fiber) with the all-confirm barrier, so everyone sees
    # the SAME "X were victorious / NNNG / item" text at the SAME time. Host-only (the guest
    # runs these post-BATTLE_END with suppress_local instead). Reset is guaranteed.
    [:process_victory, :process_defeat, :process_escape].each do |m|
      orig = :"bsmp_rp_#{m}"
      alias_method orig, m
      define_method(m) do
        BSMP::BattleMsg.result_phase = true if BSMP::BattleMsg.host_broadcasting?
        begin
          send(orig)
        ensure
          BSMP::BattleMsg.result_phase = false
        end
      end
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-BattleMessages"]
