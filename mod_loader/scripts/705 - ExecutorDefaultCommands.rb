#==============================================================================
# ExecutorDefaultCommands - the console's built-in command set, plus persistent
# key bindings.
#
# Reopens ExecutorEnvironment (defined by ExecutorScene) with the commands
# available in the F9 console: give / maptp / tp / run_event / setvar /
# setswitch / toggleswitch / gold / heal. Adds bind / unbind / binds, which map
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

  #--------------------------------------------------------------------------
  # Persistent key bindings - a ModLoader::Keyboard key -> command string,
  # stored in NVRAM (mod_loader/nvram.dat), so they survive restarts.
  #--------------------------------------------------------------------------

  # Bind a key (Symbol/String, case-insensitive) to a console command.
  #   bind :V, "win_battle"     bind :F5, "heal"
  def self.bind(key, command)
    vk = resolve_bind_key(key)
    return "Key not found" unless vk
    binds = ModLoader.nvram[:exec_binds] || {}
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

  # List current bindings.
  def self.binds
    stored = ModLoader.nvram[:exec_binds] || {}
    return "No binds" if stored.empty?
    stored.map { |vk, cmd| "#{vk} => #{cmd}" }.join("\n")
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
