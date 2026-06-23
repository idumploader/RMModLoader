#==============================================================================
# BSMP Loot — instanced loot. When an event grants items/weapons/armors/gold
# (interpreter commands 126/127/128/125 — chests, rewards, NPC gifts), broadcast
# the gain so every other player grants their OWN copy into their OWN party. The
# chest's self-switch already syncs (3a) so it can't be re-opened → no double
# grant. Personal sources (shop/menu/battle) use different code paths, not these
# commands, so they stay personal. See spec section 7.
#
# v1: deterministic, sender-broadcast with anti-echo (good for fixed loot). Only
# gains (positive amounts) are instanced, not removals. Loads after the game's
# Game_Interpreter (and mods that reopen these commands), so aliases wrap the
# final versions.
#
# Exception: some common events grant items as a PERSONAL, repeatable action that
# happens to use these same commands — the Estus/flask refill on bonfire rest and
# on death. Those must NOT instance to others (it dups flasks). They're tagged via
# Config::PERSONAL/SHARED_COMMON_EVENT_IDS; the interpreter running such a CE (and
# any CE it calls) carries @bsmp_local_ce, and bsmp_broadcast_loot skips while set.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Loot"]
$imported["IDL-BSMP-Loot"] = "1.0"

if defined?(BSMP)

class Game_Interpreter

  alias bsmp_orig_command_125 command_125
  def command_125
    bsmp_orig_command_125
    bsmp_broadcast_loot(3, 0, operate_value(@params[0], @params[1], @params[2]))
  end

  alias bsmp_orig_command_126 command_126
  def command_126
    bsmp_orig_command_126
    bsmp_broadcast_loot(0, @params[0], operate_value(@params[1], @params[2], @params[3]))
  end

  alias bsmp_orig_command_127 command_127
  def command_127
    bsmp_orig_command_127
    bsmp_broadcast_loot(1, @params[0], operate_value(@params[1], @params[2], @params[3]))
  end

  alias bsmp_orig_command_128 command_128
  def command_128
    bsmp_orig_command_128
    bsmp_broadcast_loot(2, @params[0], operate_value(@params[1], @params[2], @params[3]))
  end

  # A fresh command list starts non-local; command_117 (or an explicit caller)
  # re-marks it. Clearing here stops the flag leaking onto the next event a reused
  # interpreter (e.g. $game_map.interpreter) runs after a local CE finishes.
  alias bsmp_orig_setup_loot setup
  def setup(*args)
    bsmp_orig_setup_loot(*args)
    @bsmp_local_ce = false
  end

  # Full override of BS2's command_117 (39 - Game_Interpreter): it runs the called
  # common event on a SYNCHRONOUS child (child.run) and keeps `child` in a local
  # var an alias can't reach. We replicate it verbatim and tag the child
  # @bsmp_local_ce when the CE is a "local" one (Config::*_COMMON_EVENT_IDS) or when
  # WE already are, so nested CEs inherit it. The tag is per-interpreter (NOT a
  # global) so it survives the CE's ShowText/wait Fiber.yields without leaking onto
  # other interpreters. Item/gold gains inside a local CE then stay per-peer (Souls
  # Estus refill on bonfire rest / death) instead of dup-instancing via
  # bsmp_broadcast_loot below.
  def command_117
    common_event = $data_common_events[@params[0]]
    if common_event
      child = Game_Interpreter.new(@depth + 1)
      child.setup(common_event.list, same_map? ? @event_id : 0)
      child.instance_variable_set(:@bsmp_local_ce, @bsmp_local_ce || BSMP.local_ce?(@params[0]))
      # Co-op death/loss mirror (step 6.5): when the battle authority's real IfLose
      # calls a SHARED common event (death), tell every other peer to run the same
      # one. Gated on !@bsmp_local_ce so a peer REPLAYING a received mirror (its run
      # is loot-local) can't re-broadcast and loop. A non-shared loss broadcasts
      # nothing, so guests no longer wrongly die on scripted cutscene losses.
      if BSMP.shared_ce?(@params[0]) and not @bsmp_local_ce and bsmp_network_running?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::MIRROR_CE, 0, @params[0].to_s))
      end
      child.run
    end
  end

  # type: 0=item 1=weapon 2=armor 3=gold. Only positive (gains) are instanced; not
  # while applying a received loot fact (anti-echo) and only when networked.
  def bsmp_broadcast_loot(type, id, amount)
    return if amount <= 0
    return if @bsmp_local_ce  # inside a personal/death CE: items stay on this peer
    return if $bsmp_applying_loot or not bsmp_network_running?
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::LOOT_GAIN, 0, "#{type};#{id};#{amount}"))
  end

  # Apply a received loot gain by running the real command on this (throwaway)
  # interpreter, with @params shaped as a constant increase. Honors the game's own
  # command_* hooks (popup etc.). The re-broadcast is suppressed by $bsmp_applying_loot.
  def bsmp_run_gain(command_id, params)
    @params = params
    send(command_id)
  end

end

#==============================================================================
# ■ Game_Party — broadcast world-unique covenant tokens (spirits)
#==============================================================================
# add_spirit is a Script call (CE817 on covenant level-up), not a ChangeItems command,
# so the loot hooks above miss it. The token should reach every co-op player. Broadcast on
# EVERY grant — not just a locally-new one: when the granter already owns the token the add
# is a no-op here but the OTHER peer may still lack it, so it must hear about it. The
# receiver's add_spirit is idempotent (no dup), and apply_fact's guard stops the echo. Never
# rebroadcast while applying a received fact/snapshot, never offline.
class Game_Party
  # Guard: add_spirit is BS2's covenant system; in a game without it, aliasing a method
  # that doesn't exist would raise at load and break this whole script. Skip cleanly.
  if method_defined?(:add_spirit)
    alias bsmp_orig_add_spirit add_spirit
    def add_spirit(spirit_id)
      bsmp_orig_add_spirit(spirit_id)
      if not $bsmp_applying_fact and bsmp_network_running?
        bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::SPIRIT_GAIN, 0, spirit_id.to_s))
      end
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Loot"]
