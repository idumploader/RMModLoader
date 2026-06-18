#==============================================================================
# ExecutorDefaultCommands - the console's built-in command set, plus persistent
# key bindings.
#
# Reopens ExecutorEnvironment (defined by ExecutorScene) with the commands
# available in the F9 console: give / give_weapon / give_armor / maptp / tp /
# run_event / setvar / setswitch / toggleswitch / gold / setsouls / heal /
# sethp / setmp / set_param / setmaxhp / setmaxmp / setatk / setsec / setmagatk
# / setmagdef / setdex / setluck / win_battle / noclip / auto_skip / set_skin.
# Stat setters set absolute values. Game-specific commands (auto_skip, set_skin,
# the give popups) degrade to no-ops when the host game lacks the supporting
# code. Adds bind / unbind / binds, which map
# a ModLoader::Keyboard key (e.g. :V, :F5, :SPACE) to a console command string
# and persist across restarts via ModLoader.nvram. Example:
#   bind :V, "win_battle"
# A Scene_Base#update hook fires the bound commands while the console is not
# capturing input.
#
# Guard: only loads if ExecutorEnvironment is defined (ExecutorScene present).
#==============================================================================

if Object.const_defined?(:ExecutorEnvironment)

$imported ||= {}
if not $imported["IDL-ExecutorDefaultCommands"]
$imported["IDL-ExecutorDefaultCommands"] = "1.0"

module ExecutorEnvironment
  def self.give(id, amount)
    return "Item not found" if $data_items[id] == nil
    $game_party.gain_item($data_items[id], amount)
  end

  def self.maptp(id)
    $game_map.setup(id)
    $game_map.autoplay
  end

  def self.tp(x, y)
    $game_player.moveto(x, y)
  end

  def self.run_event(id)
    child = Game_Interpreter.new(3)
    child.setup($data_common_events[id].list, false)
    child.run
  end

  def self.setvar(id, value)
    $game_variables[id] = value
  end

  def self.setswitch(id, value)
    $game_switches[id] = value
  end

  def self.toggleswitch(id)
    $game_switches[id] ^= true
  end

  def self.gold(amount)
    $game_party.gain_gold(amount)
    "Gold: #{$game_party.gold}"
  end

  def self.heal
    $game_party.members.each { |actor| actor.recover_all }
    "Party fully healed"
  end

  # Give a weapon by id (shows the custom give popup if the game provides one).
  def self.give_weapon(id, amount)
    return "Weapon not found" if $data_weapons[id] == nil
    if Object.const_defined?(:Window_Getinfo)
      text = CUSTOM_GET_WINDOW::WEAPON_TEXT_ADD
      $game_temp.streffect.push(Window_Getinfo.new(id, 1, text, amount))
    end
    $game_party.gain_item($data_weapons[id], amount)
  end

  # Give an armor by id (shows the custom give popup if the game provides one).
  def self.give_armor(id, amount)
    return "Armor not found" if $data_armors[id] == nil
    if Object.const_defined?(:Window_Getinfo)
      text = CUSTOM_GET_WINDOW::ARMOR_TEXT_ADD
      $game_temp.streffect.push(Window_Getinfo.new(id, 2, text, amount))
    end
    $game_party.gain_item($data_armors[id], amount)
  end

  # Actual stat getters per param id (a game may override these with its own
  # formula on top of param(), so we read/aim at what the player actually sees).
  PARAM_GETTERS = [:mhp, :mmp, :atk, :def, :mat, :mdf, :agi, :luk]

  #--------------------------------------------------------------------------
  # Player stats (party leader). set_param sets an ABSOLUTE stat value.
  # add_param only feeds the raw "plus" bonus, which the game runs through its
  # own formula (rate, and sometimes an extra getter override) before the stat
  # is shown. Rather than assume the formula, we measure the real slope
  # d(stat)/d(plus) with a probe and invert it - this lands on the displayed
  # value regardless of the game's param math. Returns the resulting stat (may
  # differ if clamped to param_max). Param ids: 0 mhp, 1 mmp, 2 atk, 3 def,
  # 4 mat, 5 mdf, 6 agi, 7 luk. The named set* helpers wrap it; sethp/setmp set
  # the current HP/MP.
  #--------------------------------------------------------------------------
  def self.set_param(param_id, value)
    leader = $game_party.leader
    getter = PARAM_GETTERS[param_id]
    hp, mp = leader.hp, leader.mp            # add_param/refresh can clamp these
    before = leader.send(getter)

    probe = 1000
    leader.add_param(param_id, probe)
    after = leader.send(getter)
    if after == before                       # clamped at the top - probe down
      leader.add_param(param_id, -probe)
      probe = -probe
      leader.add_param(param_id, probe)
      after = leader.send(getter)
    end
    leader.add_param(param_id, -probe)       # undo the probe

    slope = (after - before).to_f / probe
    slope = 1.0 if slope == 0
    leader.add_param(param_id, ((value - before) / slope).round)

    leader.hp, leader.mp = hp, mp            # restore current pools
    leader.send(getter)
  end

  def self.sethp(hp)
    $game_party.leader.hp = hp
  end

  def self.setmp(mp)
    $game_party.leader.mp = mp
  end

  def self.setmaxhp(value)
    set_param(0, value)
  end

  def self.setmaxmp(value)
    set_param(1, value)
  end

  def self.setatk(value)
    set_param(2, value)
  end

  def self.setsec(value)
    set_param(3, value)
  end

  def self.setmagatk(value)
    set_param(4, value)
  end

  def self.setmagdef(value)
    set_param(5, value)
  end

  def self.setdex(value)
    set_param(6, value)
  end

  def self.setluck(value)
    set_param(7, value)
  end

  # Set gold to an absolute amount (gold() gains a delta; this sets the total).
  def self.setsouls(amount)
    $game_party.gain_gold(amount - $game_party.gold)
    "Gold: #{$game_party.gold}"
  end

  #--------------------------------------------------------------------------
  # Battle / map cheats.
  #--------------------------------------------------------------------------

  # Instantly defeat every enemy in the current battle.
  def self.win_battle
    return "Not in battle" unless $game_troop
    $game_troop.members.each { |enemy| enemy.add_new_state(enemy.death_state_id) }
    "Battle won"
  end

  # Toggle walk-through-walls for the player.
  def self.noclip
    $game_temp.exec_noclip_enabled ||= false
    $game_temp.exec_noclip_enabled ^= true
    $game_player.instance_variable_set(:@through, $game_temp.exec_noclip_enabled)
    $game_temp.exec_noclip_enabled ? "Noclip enabled" : "Noclip disabled"
  end

  # Toggle auto-skip of all dialogs (needs the game's M_SKIP seal module).
  def self.auto_skip
    return "Auto-skip unavailable" unless Object.const_defined?(:M_SKIP)
    $game_temp.exec_bs_auto_skip ^= true
    $game_temp.exec_bs_auto_skip ? "Auto-skip enabled" : "Auto-skip disabled"
  end

  # Re-skin the player from an actor's graphics. Game-specific: needs a player
  # that exposes #actor with #set_graphic.
  def self.set_skin(actor_id)
    actor_data = $data_actors[actor_id]
    return "Character not found" unless actor_data
    return "Unsupported in this game" unless $game_player.respond_to?(:actor)
    $game_player.actor.set_graphic(actor_data.character_name, actor_data.character_index,
                                   actor_data.face_name, actor_data.face_index)
    $game_player.refresh
    sprintf("Character set to: %s", actor_data.character_name)
  end

  #--------------------------------------------------------------------------
  # Persistent key bindings - a ModLoader::Keyboard key -> command string,
  # stored in NVRAM (mod_loader/nvram.dat), so they survive restarts.
  #--------------------------------------------------------------------------

  # Bind a key (Symbol/String, case-insensitive) to a console command. With no
  # command, returns the key's current binding instead.
  #   bind :V, "win_battle"     bind :F5, "heal"     bind :F5   # shows current
  def self.bind(key, command = nil)
    vk = resolve_bind_key(key)
    return "Key not found" unless vk
    binds = ModLoader.nvram[:exec_binds] || {}
    return (binds[vk] || "#{key} is not bound") if command.nil?
    binds[vk] = command
    ModLoader.nvram[:exec_binds] = binds        # one write-through
    "Bound #{key} -> #{command}"
  end

  # Remove a previously bound key.
  def self.unbind(key)
    vk = resolve_bind_key(key)
    return "Key not found" unless vk
    binds = ModLoader.nvram[:exec_binds] || {}
    removed = binds.delete(vk)
    ModLoader.nvram[:exec_binds] = binds
    removed ? "Unbound #{key}" : "#{key} was not bound"
  end

  # List current bindings (key name => command).
  def self.binds
    stored = ModLoader.nvram[:exec_binds] || {}
    return "No binds" if stored.empty?
    stored.map { |vk, cmd| "#{ModLoader::Keyboard.name(vk) || vk} => #{cmd}" }.join("\n")
  end

  # Resolve a key name to its VK code via ModLoader::Keyboard. Case-insensitive,
  # strict lookup (no inherited/global constants). Returns nil if unknown.
  def self.resolve_bind_key(key)
    name = key.to_s.upcase
    return nil unless ModLoader::Keyboard.const_defined?(name, false)
    ModLoader::Keyboard.const_get(name, false)
  rescue NameError
    nil
  end
end

# Cheat state lives on Game_Temp so it resets with a new game / load.
class Game_Temp
  attr_accessor :exec_bs_auto_skip
  attr_accessor :exec_noclip_enabled
end

# auto_skip support: when enabled, the dialog seal always reports "sealed" so the
# game fast-forwards. Only patched if the host game ships M_SKIP.
if Object.const_defined?(:M_SKIP)
  module M_SKIP
    class << self
      alias exec_orig_seal seal
    end

    def self.seal
      return exec_orig_seal unless $game_temp.exec_bs_auto_skip
      true
    end
  end
end

class Scene_Base
  alias exec_defcmds_orig_update update

  def update
    exec_defcmds_orig_update
    exec_defcmds_process_binds unless $executor_input_is_disabled
  end

  def exec_defcmds_process_binds
    binds = ModLoader.nvram[:exec_binds]
    return unless binds
    binds.each do |key, command|
      begin
        ExecutorEnvironment.execute(command) if ModLoader.input_trigger?(key)
      rescue Exception => error
        p "[exec bind] #{command}: #{error}"
      end
    end
  end
end

end # not $imported["IDL-ExecutorDefaultCommands"]

end # if Object.const_defined?(:ExecutorEnvironment)
