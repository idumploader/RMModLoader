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

  # type: 0=item 1=weapon 2=armor 3=gold. Only positive (gains) are instanced; not
  # while applying a received loot fact (anti-echo) and only when networked.
  def bsmp_broadcast_loot(type, id, amount)
    return if amount <= 0
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

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Loot"]
