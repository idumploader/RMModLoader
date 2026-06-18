# Console Commands

Reference for the built-in commands of the developer console (**ExecutorScene**,
opened with **F9**). Type a command and press **Enter**; the return value is
printed to the console.

The console evaluates arbitrary Ruby, so any expression works
(`$game_party.gold`, `p $game_map.map_id`, …). The commands below are
convenience helpers defined on `ExecutorEnvironment` by **ExecutorDefaultCommands**
(`705 - ExecutorDefaultCommands.rb`).

> [!NOTE]
> The console is **disabled by default**. Enable it from a user script:
> ```ruby
> if ModLoader.version != "2.4" and Object.const_defined?(:ExecutorModule)
>   ExecutorModule::ENABLED = true
> end
> ```

> [!NOTE]
> Some commands depend on game-specific code and degrade to a no-op message when
> the host game lacks it. These are marked **(game-specific)** below.

## Items & equipment

| Command | Description |
|---------|-------------|
| `give(id, amount)` | Give `amount` of item `id` |
| `give_weapon(id, amount)` | Give `amount` of weapon `id` |
| `give_armor(id, amount)` | Give `amount` of armor `id` |

`give_weapon` / `give_armor` show the custom give popup if the game provides one
(`Window_Getinfo`); otherwise they just add the item.

## Player stats

Applied to the party leader (`$game_party.leader`).

| Command | Description |
|---------|-------------|
| `sethp(hp)` | Set current HP |
| `setmp(mp)` | Set current MP |
| `set_param(id, value)` | Set parameter `id` to `value` (generic) |
| `setmaxhp(value)` | Set max HP |
| `setmaxmp(value)` | Set max MP |
| `setatk(value)` | Set attack |
| `setsec(value)` | Set defense |
| `setmagatk(value)` | Set magic attack |
| `setmagdef(value)` | Set magic defense |
| `setdex(value)` | Set agility |
| `setluck(value)` | Set luck |

> [!NOTE]
> All stat setters set an **absolute** value. RGSS3 computes
> `param = (base + plus) * rate` and `add_param` only adds to `plus`, so
> `set_param` inverts the rate to land exactly on the requested value (a value
> above the engine's `param_max` is clamped). The named helpers wrap
> `set_param`; param ids are `0` mhp, `1` mmp, `2` atk, `3` def, `4` mat,
> `5` mdf, `6` agi, `7` luk. `setsec`/`setdex` map to the engine's defense and
> agility parameters.

## Economy

| Command | Description |
|---------|-------------|
| `gold(amount)` | Gain `amount` gold (negative to spend) |
| `setsouls(amount)` | Set gold to an absolute `amount` |

## Party

| Command | Description |
|---------|-------------|
| `heal` | Fully recover the whole party (HP/MP/states) |

## Map & teleport

| Command | Description |
|---------|-------------|
| `tp(x, y)` | Move the player to map tile `(x, y)` |
| `maptp(id)` | Transfer to map `id` and start its autoplay BGM/BGS |

## Events, variables & switches

| Command | Description |
|---------|-------------|
| `run_event(id)` | Run common event `id` |
| `setvar(id, value)` | Set game variable `id` to `value` |
| `setswitch(id, value)` | Set game switch `id` to `value` (`true`/`false`) |
| `toggleswitch(id)` | Flip game switch `id` |

## Battle & movement cheats

| Command | Description |
|---------|-------------|
| `win_battle` | Instantly defeat every enemy in the current battle |
| `noclip` | Toggle walk-through-walls for the player |
| `auto_skip` | **(game-specific)** Toggle auto-skip of all dialogs (needs the game's `M_SKIP` seal module) |
| `set_skin(actor_id)` | **(game-specific)** Re-skin the player from actor `actor_id`'s graphics (needs a player exposing `#actor` with `#set_graphic`) |

## Key bindings

Bind a key to a console command. Bindings persist across restarts via
`ModLoader.nvram` (`mod_loader/nvram.dat`) and fire while the console is not
capturing input. Keys are resolved through
[`ModLoader::Keyboard`](../mod_loader/scripts/7%20-%20ModLoaderKeyboard.rb)
(case-insensitive name, e.g. `:V`, `:F5`, `:SPACE`).

| Command | Description |
|---------|-------------|
| `bind(key, command)` | Bind `key` to a command string, e.g. `bind :V, "win_battle"` |
| `bind(key)` | Show the command currently bound to `key` |
| `unbind(key)` | Remove the binding on `key` |
| `binds` | List all bindings as `key name => command` |

Examples:

```ruby
bind :V, "win_battle"     # press V to win the current battle
bind :F5, "heal"          # press F5 to heal the party
bind :F5                  # => "heal"
binds                     # => "V => win_battle\nF5 => heal"
unbind :V                 # => "Unbound V"
```

## Other console-callable helpers

These live in other built-in scripts but are callable from the same console:

| Command | Source | Description |
|---------|--------|-------------|
| `reset` | ModResetter | Restore the snapshot and reload all scripts (also `mod_reset`) |
| `dump_rvdata("folder")` | GameDumper | Dump all game files (including packaged) to `folder` |
