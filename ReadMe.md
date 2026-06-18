# RMModLoader

A mod loader for **RPG Maker VX Ace** — allows you to execute custom Ruby scripts, replace game assets, and modify engine behavior without editing the original game files.

> [!NOTE]
> Currently, only RGSS version **3.0.1.1** is supported.

## Contents

- [Features](#features)
- [Usage](#usage)
- [Build](#build)
- [Built-in Scripts](#built-in-scripts)
- [Configuration](#configuration)
- [`ModLoader` Ruby Module](#modloader-ruby-module)
- [Known Issues](#known-issues)
- [Antivirus False Positives](#antivirus-false-positives)
- [References & Dependencies](#references--dependencies)

## Features

- **Custom scripts** — run Ruby scripts from `mod_loader/scripts` (after game scripts) and `mod_loader/scripts_preinit` (before the engine loads)
- **Asset replacement** — swap graphics, audio, and other files at runtime (`GraphicsReplace`)
- **HRFix** — fix resolution issues above 640×480
- **Controls customization** — remap keys and enable gamepad support (`ControlsChange`)
- **Script reset** — restore Ruby environment state and reload scripts (`ModResetter`)
- **Developer console** — execute arbitrary Ruby code during gameplay, with built-in commands and persistent key bindings (`ExecutorScene`; see [docs/console-commands.md](docs/console-commands.md))
- **Item give window** — quickly search and obtain items, weapons, and armor (`MapExecutorWindow`)
- **Crash fix** — guards against the battle-start crash and a double-dispose use-after-free in RGSS sprite teardown (`SpriteDisposeFix`)
- **Focus control** — optionally keep the game running while its window is in the background, without leaking background input (`disable_focus_pause`)
- **HTTP server** — optional local HTTP API for external tooling (see [docs/http-server-spec.md](docs/http-server-spec.md))

## Usage

1. Get a build — from the **[Releases](../../releases)** tab, or as an artifact from the latest **[Actions](../../actions)** run (the workflow uploads one on every run; downloading an artifact requires being signed in to GitHub), or [build it manually](#build)
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
| **ExecutorScene** (console) | Developer console. Opens with **F9** during gameplay. Executes arbitrary Ruby code with command history, plus built-in helpers (give items, teleport, set stats, win battle, noclip, persistent key bindings, …). See the full [Console Commands](docs/console-commands.md) reference |
| **MapExecutorWindow** (give) | Item/weapon/armor give window. Opens with **T** on the map. Categories switchable via tabs, shows item ID. Blocks player movement while the window is open |
| **GameDumper** | Dumps all game files (including encrypted/packaged) to a specified folder. Call via console: `dump_rvdata("folder")`. Useful for extracting assets from protected projects |

> [!WARNING]
> **GameDumper** is intended solely for debugging and inspecting your own projects. Using extracted assets for commercial purposes without the copyright holder's permission is prohibited. Respect game developers' work.

> [!NOTE]
> The developer console (**ExecutorScene**, F9) and the give window (**MapExecutorWindow**, T) are **disabled by default**. Enable them from a user script that sets `ExecutorModule::ENABLED = true`:

```ruby
if ModLoader.version != "2.4" and Object.const_defined?(:ExecutorModule)
  ExecutorModule::ENABLED = true
end
```

## Configuration

The `mod_loader/mod_loader.json` file contains loader settings:

| Parameter | Description |
|-----------|-------------|
| `hrfix_enable` | Enable/disable HRFix (default `true`) |
| `controls_change` | Enable/disable ControlsChange (default `true`) |
| `fast_render` | Fast rendering (default `false`). **Does not work**, no point enabling |
| `steam_support` | Steam support (default `false`) |
| `disable_focus_pause` | Keep the game ticking when the window loses focus (default `false`). Filters `WM_ACTIVATEAPP`/`WM_KILLFOCUS`/`WM_ACTIVATE` out of the message queue so the engine never marks itself inactive. Useful for tools that need the game to keep running in the background. |
| `width` | Render width. Only applies with `hrfix_enable` (default `640`) |
| `height` | Render height. Only applies with `hrfix_enable` (default `480`) |
| `steam_overlay` | Render the Steam overlay for games that lack it (default `false`). Best paired with `hrfix_enable` |
| `sprite_dispose_fix` | Guard against sprite-dispose crashes / use-after-free (default `true`) |
| `http_port` | Port for the built-in HTTP server (default `27420`) |
| `rgss_library` | Override the RGSS runtime DLL path. Normally auto-detected from `Game.ini` (`[Game] Library=`); set only for non-standard / protected games |

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

## Antivirus False Positives

Some antivirus engines flag `Loader.exe` — the injector that launches the game and loads the DLL, which to a heuristic looks exactly like a malware loader (`ModLoader.dll` itself is usually clean). This is a **heuristic false positive**, not actual malware:

- The loader injects a DLL into the game process and installs inline hooks (via [MinHook](https://github.com/TsudaKageyu/minhook)) on RGSS functions — the same technique cheats and malware use, so generic heuristics flag it.
- The release binaries are **unsigned** (no code-signing certificate), which pushes the heuristic score higher.

What you can do:

- **Build it yourself** from source (see [Build](#build)) so you run a binary you compiled.
- Add the loader files to your antivirus **exclusions**.
- Check the binary on [VirusTotal](https://www.virustotal.com/) — the few hits are generic/heuristic labels (e.g. `Mal/EncPk-ACO`, `encpk`, ML-score names) that **come and go between rescans**, not a specific known threat. A real threat would be flagged consistently by many engines, not by the 3–5 that keep changing.

If you would rather not trust a prebuilt binary, building from source is always the safe option.

## References & Dependencies

- [App icon](https://www.flaticon.com)
- [nlohmann/json](https://github.com/nlohmann/json) — JSON config parsing
- [minhook](https://github.com/TsudaKageyu/minhook) — RGSS function hooking
- [mkxp-z](https://github.com/mkxp-z/mkxp-z) — open-source RPG Maker engine implementation
