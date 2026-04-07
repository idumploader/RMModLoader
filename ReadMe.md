# RMModLoader

A mod loader for **RPG Maker VX Ace** — allows you to execute custom Ruby scripts, replace game assets, and modify engine behavior without editing the original game files.

> [!NOTE]
> Currently, only RGSS version **3.0.1.1** is supported.

## Features

- **Custom scripts** — run Ruby scripts from `mod_loader/scripts` (after game scripts) and `mod_loader/scripts_preinit` (before the engine loads)
- **Asset replacement** — swap graphics, audio, and other files at runtime (`GraphicsReplace`)
- **HRFix** — fix resolution issues above 640×480
- **Controls customization** — remap keys and enable gamepad support (`ControlsChange`)
- **Script reset** — restore Ruby environment state and reload scripts (`ModResetter`)
- **Developer console** — execute arbitrary Ruby code during gameplay (`ExecutorScene`)
- **Item give window** — quickly search and obtain items, weapons, and armor (`MapExecutorWindow`)

## Usage

1. Download the release from the **[Releases](../../releases)** tab or [build manually](#build)
2. Extract all files to the game folder
3. Run `Loader.exe`

## Build

1. Clone the repository: `git clone --recursive https://github.com/idumploader/RMModLoader`
2. Open the solution in **Visual Studio**
3. Build the project (Build → Build Solution)

## Built-in Scripts

| Script | Description |
|--------|-------------|
| **GraphicsReplace** | Replaces in-game assets at runtime. Looks for files in `mod_loader/`. For example, `mod_loader/Graphics/Pictures/my_game_title.png` replaces in-game `Graphics/Pictures/my_game_title.png` |
| **HRFix** | Fixes issues with higher screen resolutions. Only works when `"hrfix_enable": true` in config |
| **ControlsChange** | Allows key remapping and enables gamepad support. Only works when `"controls_change": true` in config |
| **ModResetter** | Takes a snapshot of all Ruby classes and methods at startup. The `mod_reset` function restores the original state and reloads scripts. Useful for hot-reloading mods without restarting the game |
| **LocalizeLayer** | Replaces any `.rvdata2` file (including `Scripts.rvdata2`) with custom ones from `mod_loader/`. Hooks into `load_data` to intercept and substitute files. Useful for localization and modifying system data |
| **ExecutorScene** (console) | Developer console. Opens with **F9** during gameplay. Allows executing arbitrary Ruby code with command history. Available commands: `give(id, amount)` — give item, `tp(x, y)` — teleport, `maptp(id)` — teleport to map, `run_event(id)` — run common event, `setvar(id, value)` / `setswitch(id, value)` — set variables and switches |
| **MapExecutorWindow** (give) | Item/weapon/armor give window. Opens with **T** on the map. Categories switchable via tabs, shows item ID. Blocks player movement while the window is open |
| **GameDumper** | Dumps all game files (including encrypted/packaged) to a specified folder. Call via console: `dump_rvdata("folder")`. Useful for extracting assets from protected projects |

> [!WARNING]
> **GameDumper** is intended solely for debugging and inspecting your own projects. Using extracted assets for commercial purposes without the copyright holder's permission is prohibited. Respect game developers' work.

## Configuration

The `mod_loader/mod_loader.json` file contains loader settings:

| Parameter | Description |
|-----------|-------------|
| `hrfix_enable` | Enable/disable HRFix (default `true`) |
| `controls_change` | Enable/disable ControlsChange (default `true`) |
| `fast_render` | Fast rendering (default `false`). **Does not work**, no point enabling |
| `steam_support` | Steam support (default `false`) |
| `width` | Window width. Only applies when `hrfix_enable` is enabled |
| `height` | Window height. Only applies when `hrfix_enable` is enabled |

## `ModLoader` Ruby Module

The `ModLoader` module is available from any user script and provides an API for interacting with the loader:

| Method | Description |
|--------|-------------|
| `ModLoader.version` | Current loader version (string) |
| `ModLoader.version_major` | Major version number (integer) |
| `ModLoader.version_minor` | Minor version number (integer) |
| `ModLoader.data_directory` | Path to the `mod_loader/` folder (string) |
| `ModLoader.hrfix_enabled` | Whether HRFix is enabled (`true`/`false`). Prefer `config_get("hrfix_enable")` |
| `ModLoader.fast_render_enabled` | Whether fast rendering is enabled (`true`/`false`). Prefer `config_get("fast_render")` |
| `ModLoader.controls_change_enabled` | Whether controls customization is enabled (`true`/`false`). Prefer `config_get("controls_change")` |
| `ModLoader.config_get("key")` | Get a value from `mod_loader.json` by key. **Recommended way** to read settings |
| `ModLoader.log("message")` | Output a message to the loader log |
| `ModLoader.input_trigger?(key)` | Check if a key with the given virtual code is pressed |
| `ModLoader.input_repeat?(key)` | Check if a key is being held (repeat) |
| `ModLoader.map_char(key)` | Convert a virtual key code to a character |
| `ModLoader.hook_key(orig_key, new_key)` | Remap a key (orig → new) |
| `ModLoader.gamepad_bind(button, action)` | Bind a gamepad button to an action (`:Z`, `:X`, `:SHIFT`, etc.) |
| `ModLoader.gamepad_deadzone = value` | Set gamepad dead zone (0–255) |
| `ModLoader.gamepad_invert_x = bool` | Invert gamepad X axis |
| `ModLoader.gamepad_invert_y = bool` | Invert gamepad Y axis |
| `ModLoader.list_files` | Get a list of all files packaged in the game |
| `ModLoader.read_file(path)` | Read the contents of a file from the game archive (including encrypted ones) |

> [!TIP]
> You can use regular `puts` and `p` in scripts — the **ModLoaderStdout** script automatically redirects their output to the **Loader.exe** console.

## Known Issues

- HRFix can significantly reduce FPS at high resolutions

## References & Dependencies

- [App icon](https://www.flaticon.com)
- [nlohmann/json](https://github.com/nlohmann/json) — JSON config parsing
- [minhook](https://github.com/TsudaKageyu/minhook) — RGSS function hooking
- [mkxp-z](https://github.com/mkxp-z/mkxp-z) — open-source RPG Maker engine implementation
