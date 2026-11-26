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

## Parallel rendering

With the matching x86 DLL, `990 - ModLoader Runtime.rb` and the framework directory,
`Graphics.last_frame_to_bitmap` returns an independent, filled Bitmap of the
last completed game screen, without submitting or waiting for another render.
Dispose it like any other Bitmap. If there is no valid frame (startup, reset,
resize, unavailable backend), it falls back to the ordinary `snap_to_bitmap`.
Menu background snapshots through `SceneManager.snapshot_for_background`,
including backgrounds taken from the title screen, use this method and retain
the game's blur/disposal wrappers. Other snapshots still render the current tree.
The image contains the complete composed scene, including HUD/notifications;
it does not isolate the map viewport or capture the Steam overlay. Static title
art continues to load normally.

Full-size RGSS screen buffers are borrowed until the next screen draw; their
destruction, reinitialization and external pixel writes invalidate the borrow.
Before an explicit render/readback overwrites a borrowed frame, an owned copy
preserves it. Parallel frames retain an existing completed renderer surface.
The stock strip path keeps one assembled screen buffer (width × height × 4
bytes plus existing Surface accounting), within the renderer memory budget.
`ModLoader.last_frame_enable(false)` releases this optional cache;
`ModLoader.last_frame_status` reports readiness, readback hits and copy timings.
Display -> Rendering -> Last frame menu background switches it ON/OFF immediately and saves the choice in NVRAM; ON is the default. The supplied script restores the choice on load/F12. A borrowed buffer itself belongs to RGSS
and adds no owned renderer buffer. Returned Ruby Bitmaps belong to the game.

With `fast_render: false` in `mod_loader/mod_loader.json`, open **Display → Rendering**
and enable **Parallel rendering**. The selection, **Wait for new frame**, and the
renderer memory limit are saved. F12 clears the old worker and restores the
saved settings before the next scene starts. Parallel rendering may temporarily
use the original renderer for unsupported ViewportEffects or when a frame
exceeds the renderer memory limit; it resumes when the condition ends. Other
renderer errors disable the mode and appear in its Display description and
the Loader log. Turning Parallel rendering off restores the original renderer.

The Ruby methods below expose the snapshot engine for diagnostics and testing.
The canonical native API uses `parallel_renderer_*`; old `render_snapshot_probe_*`
methods and the `RenderSnapshotProbe` Ruby alias remain available.

With the matching x86 DLL, `990 - ModLoader Runtime.rb` and the framework directory, the methods can
also capture and draw a snapshot explicitly:

```ruby
probe = ModLoader::ParallelRenderer
Graphics.update
probe.capture(viewport)
probe.start(template_bitmap) # copies the template; returns without waiting for rendering
# Original sprites, bitmaps, viewport and template may now change or be disposed.
probe.collect(result_bitmap) # waits, then copies pixels; same dimensions as template
puts probe.status
probe.clear
```

One persistent native worker processes up to two pending frames in FIFO order.
Use `submit` to capture and enqueue each frame independently:

```ruby
probe.submit(viewport, template_bitmap)
# Update scene/game logic while the detached frame renders.
probe.submit(viewport, template_bitmap)
probe.collect(result_bitmap) # oldest frame; frees one queue slot
probe.collect(result_bitmap) # second frame
```

Submitting a third frame raises an error, preserving both pending frames.
Completed but uncollected frames still occupy slots. Failed submissions also
preserve existing jobs. Each job owns a copied tree and an independent target;
source copies can be shared as immutable versions between frames.
The worker calls no Ruby API and bypasses custom ViewportEffects using a
thread-local flag. `start(template, repeats)` retains the single-job interface
and requires an empty queue; its `collect` restores the snapshot for synchronous
`draw` or another `start`. Both submission methods accept 1–10000 repetitions
for stress testing, restoring template pixels before each render.
`clear` and replacement capture wait before freeing pending jobs, retaining the
worker thread. RGSS main-loop exit drains the queue and stops the worker outside
the DLL loader lock.

### Bitmap cache and target reuse

With an empty queue, select a cache mode using `probe.optimization(mode)`:

| Mode | Source Bitmap copies | Output storage |
|------|----------------------|----------------|
| `0` (default) | Copy each snapshot | Allocate each job |
| `1` | Cache immutable versions | Allocate each job |
| `2` | Cache immutable versions | Reuse up to two targets and background buffers |

Standard RGSS Bitmap writers invalidate the cache through native hooks:
`blt`, `stretch_blt`, `fill_rect`, `gradient_fill_rect`, `clear`, `clear_rect`,
`set_pixel`, `hue_change`, `blur`, `radial_blur`, `draw_text`. Surface destruction
and reinitialization evict the original pointer; pending snapshots keep their
old copies alive. The probe's own draw/reference/collect writes also invalidate
their destinations. Native extensions that write pixels outside these paths
must call `probe.invalidate(bitmap)` after writing, before submitting a frame,
or use mode `0`. This is not automatic tracking of arbitrary native writes.

The shared renderer budget defaults to 256 MiB and permits 32–512 MiB. It counts
pixel buffers, cached versions (including versions retained by pending frames),
queued backgrounds, snapshot nodes and Tilemap tables. Game allocations, thread
stacks and allocator/container overhead are additional; this is not a process
memory cap. `ModLoader::ParallelRenderer.memory_limit_mib = 192` changes and saves
the same setting as Display. Old test-build settings are not migrated.
`clear` drains jobs but keeps the cache and reusable targets. Switching
mode clears both and resets counters; it rejects pending frames. Target size
changes reallocate storage. The background still gets copied every submission,
and collect still copies the completed image into a Ruby Bitmap.

Status exposes `source_copied_bytes`, `cache_hits`, `cache_misses`, `cache_bytes`
and `target_reuses`. For native correctness and performance tests, load
`tests/render_snapshot_cache_rgss.rb` after the smoke script and call
`RenderSnapshotCache.run` / `RenderSnapshotCache.benchmark`.
See [renderer options](docs/RENDERER_OPTIONS.md) for the saved display settings.
HRFix benchmarks must run in a fresh process per configured resolution and verify
`Graphics.width/height`; `Graphics.resize_screen` did not apply the requested
screen sizes in the initial cache matrix (the output Bitmaps did have those sizes).
For native live-tree clear/draw timing without snapshot costs, load
`tests/render_snapshot_original_rgss.rb` after the smoke/cache helpers and call
`RenderSnapshotOriginal.run`. It excludes logic, presentation and FPS waiting.

Supported snapshot nodes include ordinary and rotated sprites, surface sprites,
Tilemap, Plane, the native sprite trees used by Window, and native viewport effects.
Custom ViewportEffects require live rendering. Main-thread game rendering continues normally.
Manual operations do not change `Graphics.update` by default.

`capture_frame`, `submit_frame(template, repeats=1)` and `reference_frame(bitmap)`
use the complete native Screen tree, preserving its draw order and background.
Every descendant must be supported; unsupported nodes reject the capture.

For direct Ruby control of the frame loop, call
`ModLoader.parallel_renderer_frame_mode(mode)`:

- `0`: normal rendering (default); drains pending work and releases the worker,
  cache and reusable renderer buffers.
- `1`: capture and synchronously draw a Screen snapshot inside Graphics.update.
- `2`: enqueue the current Screen and copy the previous result into the regular
  screen target. The engine then presents it normally. One render of latency is
  introduced; RGSS frame skipping and FPS pacing remain active. The first frame
  uses normal rendering to prime the queue.
- `3`: poll the bounded queue without waiting. Present the newest completed
  result and discard older completed results; otherwise repeat the last image.
  Submit while a slot is available, up to two outstanding jobs.
  A synchronous image bootstraps the first presentation.
  The retained surface cannot be reused by the worker until it is replaced.

Reference validation is off during ordinary gameplay. Explicit diagnostics can
enable it with `ModLoader::ParallelRenderer.validation = true`: the first six
queued frames are then checked pixel-for-pixel; benchmark after warmup.
`parallel_renderer_frame_status` reports mode,
submissions, collections, checks, capture/submission, wait/copy and worker time,
cache counters and any error. Modes 2 and 3 temporarily use normal rendering for
custom ViewportEffects, reports `fallback=true` / `fallback_frames`, and resumes
asynchronous rendering once the effect ends. This is compatibility fallback,
not worker support for those effects. Other caught errors disable automatic
rendering; inspect the error field.
Manual snapshot operations are rejected while automatic mode is enabled.
Disable it with mode 0 before scene cleanup, manual tests or changing snapshot
settings. `Graphics.freeze` and `Graphics.transition` drain obsolete queued
images. A Ruby ensure around each rgss_main iteration drains workers on reset
and exit. RGSSReset clears the active mode; a saved Display selection restores
it before the next scene starts.

Mode 3 additionally reports `repeated_frames` and cumulative `age_ms` from
snapshot capture to collection (divide by `collects`; this is not end-to-end
input latency). Count new images using `collects - skipped_results`, not Screen render calls:
the latter include repeated images. Normal mode-3 updates never wait for a
job, but shutdown, switching modes and error fallback still drain pending work.
Compare with `.tools/run-nonblocking-matrix.py`; select a new artifact prefix
before repeating a matrix so previous measurements are retained.

Rotation uses the original RGSS algorithm: its lazy cache is prepared on the
owner thread, then copied into the snapshot. Worker replay never rebuilds it
or reads the live viewport registry. Rotation-cache pixels are copied on every
capture because native writes bypass Bitmap invalidation. Ordinary Bitmap
versions still use the existing cache. Window tests cover skin/contents changes,
cursor, opacity, scrolling, opening, resizing and original-object disposal.
`tests/render_snapshot_objects_rgss.rb` is part of the native regression.
`.tools/run-lifecycle.py` checks real Map080/Menu/Item transitions;
`.tools/run-render-reset.py` raises RGSSReset with a worker pending and checks
cleanup (it does not inject a physical F12 key). `.tools/run-display-f12.py`
checks restoration of the saved Display mode on Map093.

For installation, use the matching x86 DLL and scripts, set `fast_render` to
`false`, restart the game, then open **Display → Rendering**:

- **Parallel rendering** applies immediately, enabling the Bitmap cache and
  pooled targets; Off restores original rendering. The selection is saved.
- **Wait for new frame** selects waiting (mode 2) or nonblocking (mode 3).
  Default is Off; this preference is saved. Available only while parallel
  rendering is on.
- **Renderer memory limit** changes the shared budget, 32–512 MiB in steps of
  16 MiB, default 256 MiB; the setting is saved.
- **Renderer warnings** is off by default. When enabled it polls one integer
  every 60 Graphics updates and displays a small warning during effect/memory
  fallback or after an error stops the renderer. It redraws only when the state
  changes. Details remain in Display and the Loader log.

Both HRFix full-frame rendering and the original strip presentation are supported.
Without HRFix, all strips of one presentation use the same completed snapshot.

Controls are disabled when `fast_render` is on or the native support is missing.
The displayed On/Off state follows the native renderer, including error/reset.
The console API remains available for diagnostics: inspect
`ModLoader.parallel_renderer_frame_status` for errors/fallback.
Compare walking/camera response, map/menu transitions and long sessions manually.

Tilemap snapshots deep-copy map_data, flags and flash_data (64 MiB table limit),
animation/scroll state, and share one copied state between the two layer nodes.
Tileset surfaces use the same version cache as sprite Bitmaps. The snapshot's
tile loop has local bounds and reuses RGSS tile/autotile/shadow drawing helpers;
it never enters HRFix's loop that patches shared instruction bytes. Status adds
`tilemaps` and `table_bytes`. Map tables are currently copied on every capture.
Tables with fewer than four map layers and tile render bounds above 127 cells
are rejected. Standard RGSS/HRFix layouts are required; arbitrary native Tilemap
extensions are outside the supported snapshot layouts.

`tests/render_snapshot_tilemap_rgss.rb` checks sync/worker pixel equality,
animation, scrolling, layer ordering, table edges, shadows, flash, queued old/new
versions and original disposal/GC. Its Map080 check uses a dedicated viewport
with actual map assets and copied character sprite parameters.

Plane snapshots bake the live viewport's ox/oy into the captured Plane origin.
Their independent tiling loop uses the copied surface, zoom, tone, color,
opacity and blend attributes, without reading RGSS's global viewport registry.
Negative/non-finite or excessively large resulting Plane dimensions are rejected.
`tests/render_snapshot_plane_rgss.rb` checks all three cache modes, fractional
zoom, negative scrolling, viewport origin, tone/color, opacity/blends, FIFO
versions and disposal while another live viewport is created. Its Map080 check
captures the actual Spriteset_Map viewport1, including Plane nodes, and compares
reference/snapshot pixels plus queued replay during live scene updates. Other
viewports and final screen presentation are not part of that comparison.

`parallel_renderer_snapshot_benchmark(viewport, bitmap, repeats)` benchmarks
clear + drawing the previously captured tree, with the same native timer as
`parallel_renderer_original_benchmark`. Both report `original_*` timing
fields for historical compatibility; the caller must label the tested mode.
These exclude snapshot capture, submit/collect, logic and presentation.

In the game console, load `tests/render_snapshot_rgss_smoke.rb`, then run
`RenderSnapshotSmoke.run` and `RenderSnapshotSmoke.run_worker`. The latter checks
pixel equality for plain, transform, wave, tone and empty scenes across 10000
replays each, concurrent original disposal/GC and `Graphics.update`, template
ownership, separate thread IDs, pending-job rejection, destination size checks
and clear/restart. `RenderSnapshotSmoke.run_queue` checks ordered frames,
queue overflow, failed capture, draining and persistent thread identity.
It requires the game's `Viewport#disposed?` compatibility
method (the standalone test harness supplies it).

The native RGSS301/Ruby 1.9.2 test passed on 2026-10-10 with HRFix and
ViewportEffects enabled. This validates the exercised cases, not arbitrary
engine branches, full game scenes or F12 during an active job. Status fields
`last_worker_ms`, `last_worker_thread`, and `last_worker_repeats` describe the
last collected job; its time includes background restoration and rendering,
excluding capture, thread creation, result collection and presentation.
Queue status includes `queue_depth`, `queue_capacity`, `next_frame`, `last_frame`,
`last_submit_ms`, `last_wait_ms` and `last_collect_ms` (copy and job cleanup).

`RenderSnapshotSmoke.benchmark_queue` compares serial capture/draw with queued
rendering, including synthetic Ruby logic and capture/collection costs. On
2026-10-10, two runs per mode of 40 frames (640×480, 80 sprites, viewport tone)
averaged 214.814 ms serial versus 229.662 ms queued: the queue was about 7% slower.
Final pixels matched the reference. This benchmark excludes presentation and
does not establish game FPS.

## Map frame profiling

Call `ModLoader.map_frame_probe_start` and `ModLoader.map_frame_probe_stop`
(JSON) to record diagnostics. No configuration flag is required.
This measures the native Graphics.update, screen composition and FPS scheduler.
`rendered_updates` counts updates that actually draw; RGSS can skip rendering.
Divide `render_ms` by this count, not by `updates`.

With HRFix enabled, `tilemap_ms` times its complete tile drawing hook, including
the original RGSS tile loop. `tilemap_calls` counts layer calls, not frames.
Viewport capture instrumentation reports inclusive `viewport_total_ms`,
`viewport_subtree_ms`, and their difference `viewport_overhead_ms`. The subtree
already includes Tilemap: do not add inclusive viewport time to Tilemap time.
The overhead includes buffer preparation and final composition/scaling.
`custom_viewports` counts active zoom, rotation, flip, wave, blur or pixelize
passes; `scaling_viewports` counts capture passes without those effects,
including HRFix's fixed map size. These counters cover the custom viewport
path, not native tone/color effects. Outside an active measurement the scope
timers do not read the clock. Profiling is disabled by default.

`tests/map080_rgss_benchmark.rb` is intended only for an isolated game copy:
it replaces scene startup and neutralizes input for repeatable idle measurements.

### Internal script components and lifecycle

The native renderer keeps surface allocation, RGSS surface bindings and versioned
copies in `Hooks/Renderer/SurfaceResources`. `MemoryBudget` accounts owned payloads;
`SnapshotCapture` owns copied trees, using a temporary game-thread capture context;
`SnapshotExecution` replays them without Ruby values or live cache references.
`SnapshotReplay` supplies tile/Plane draw implementations and `WorkerQueue` owns
job scheduling. `RendererService` owns frame modes, queue policy and last-frame
presentation behind a typed native API. `RubyBindings` validates and decodes Ruby
values and registers methods/aliases; protected Ruby calls unwind C++ scopes before
propagating Ruby exceptions. `ParallelRenderer.cpp` is the startup adapter and
`RenderIntegration` owns the engine render/presentation hooks. `HookRegistry` owns
MinHook chains and preserves cleanup ownership when installation or removal fails.

Script priorities are numeric; equal priorities load in filename order. Native
preinit/postinit handlers run in registration order. `framework/core/lifecycle.rb`
provides keyed `register(:before_run/:cleanup, key, priority)` callbacks for each
`rgss_main` iteration, including F12. Cleanup attempts all registered callbacks.

`framework/renderer/settings.rb` separates native `RendererControl` from NVRAM-backed
`RendererSettings`; Display provides menu presentation. The matching DLL exposes
`parallel_renderer_current_mode` and `parallel_renderer_last_error` getters.
Bundled ModLoader implementations live under `mod_loader/framework`: `core`,
`input`, `display`, `renderer`, `modmenu`, `console`, `http`, `diagnostics` and
`tools`. The numbered files in `mod_loader/scripts` are startup entrypoints;
seven groups preserve loading stages around independent game scripts and BSMP:

| Entry point | Components |
| --- | --- |
| `1 - ModLoader Core.rb` | Lifecycle, input, NVRAM, ModMenu, I18n, settings |
| `245 - ModLoader Backend.rb` | Zeus native backend |
| `400 - ModLoader HRFix.rb` | HRFix and map size |
| `700 - ModLoader Console.rb` | Console, commands, game dumper |
| `990 - ModLoader Runtime.rb` | Crash log, profiler, renderer and menu rendering |
| `1040 - ModLoader HTTP.rb` | HTTP router |
| `1400 - ModLoader Tools.rb` | Map snapshot tools |

Remove the old ModLoader entrypoints when installing this layout; the matching
package lists their names. Independent game scripts and BSMP keep their locations.

`framework/loader.rb` evaluates components as UTF-8 with an absolute filename.
It supports the native loader's basename-only entrypoints and standalone Ruby
loads. Component guards still control repeated evaluation, so ModResetter can
reload them after clearing `$imported`; Ruby's `require` cache is not involved.
Native startup and Ruby reload share the priority contract: signed int64 prefix
before `" - "`, invalid names last, then complete filename for equal priorities.
NVRAM write failures restore its in-memory backing state and rethrow the error;
the file write itself is not crash-atomic.
Distribute the complete framework directory with its matching entrypoints and
DLL. Replacing only the former single-file entrypoints is insufficient.

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
| `hrfix_map_original_size` | Keep map view/camera at 640×480 and enlarge only the map layer to the render resolution (default `false`). Requires HRFix; applies after closing F10 on the map or title screen with the updated DLL/scripts |
| `steam_overlay` | Render the Steam overlay for games that lack it (default `false`). Best paired with `hrfix_enable` |
| `sprite_dispose_fix` | Guard against sprite-dispose crashes / use-after-free (default `true`) |
| `http_port` | Port for the built-in HTTP server (default `27420`). A port saved in the Debug menu takes precedence |
| `rgss_library` | Override the RGSS runtime DLL path. Normally auto-detected from `Game.ini` (`[Game] Library=`); set only for non-standard / protected games |

## HTTP server settings

The F10 menu's **General → Network** section provides **HTTP server** (OFF by
default). Switching it on or off starts or stops the local server immediately;
the choice is saved in `mod_loader/nvram.dat` for future launches. Disabling it
closes the listening port and cancels pending requests.

**HTTP port** remains editable while the server is off. Press Enter to open the
text field, edit the port with the keyboard (Backspace/Delete and Ctrl+V are
supported), then press Enter to save or Esc to cancel. Valid ports are 1–65535.
The setting is saved in `mod_loader/nvram.dat` and applies the next time HTTP is
enabled or the game restarts. It takes precedence over `http_port` in `mod_loader.json`; without a
saved setting the JSON value or default `27420` is used. F12 does not restart
the native HTTP server. The chosen port must be free when HTTP is enabled.

## Map snapshot

The F10 menu's **Debug** tab also provides **Screenshot → Snapshot this map**.
The action queues a capture and closes the menu. MapSnapshotter saves map-layer
tiles and a manifest in `mod_loader/mapshots/map<ID>/`, hiding the player and
HUD during capture. The accompanying viewport fix reacquires live map viewports
and includes RichFog while keeping HUD windows hidden.

## Glyph cache

The loader caches RGSS text glyph metrics and grayscale masks on the Ruby
thread. It is enabled by default, independently of parallel rendering. Font,
size, style, horizontal compression, glyph, format and transform distinguish
entries; RGSS still applies colors, outlines and shadows normally.

The default accounted cache budget is 8 MiB with LRU eviction, at most 4096
entries and 128 font descriptions. Allocator bookkeeping is additional; this
cache is separate from the parallel renderer's memory budget. Turning it off,
F12 and normal exit release cached glyphs. The fixed font table uses about
12 KiB even when empty. **Optimizations → Glyph cache** switches the cache
immediately and saves the choice for restart and F12. It defaults to ON;
the control is disabled with older DLLs that lack the glyph cache API.
Direct native settings below apply to the current process:

```ruby
ModLoader.glyph_cache_status        # JSON: payload/owned/peak bytes, hits/misses
ModLoader.glyph_cache_enable(false) # disable and free entries
ModLoader.glyph_cache_enable(true)
ModLoader.glyph_cache_limit_mib(4)   # accepted range: 1..32
ModLoader.glyph_cache_clear         # free entries and reset statistics
```

The first occurrence of a glyph still uses Windows GDI. The cache reduces
repeated glyph extraction and measurement; it does not move text drawing or
Bitmap snapshot copying onto the renderer worker.

## Display settings

The F10 menu's **Display** tab provides **Window mode** (Windowed / Borderless
fullscreen), **Scaling**, **Scaling filter**, **Render resolution**, and **Map size**.

Borderless uses the current monitor's desktop resolution without changing its
display mode. In both window modes, **Keep aspect ratio** (the default) fills
unused space with black bars; **Stretch** fills the entire window and may
distort the image. Window mode and scaling apply immediately and are saved in
NVRAM. Resize the window with its borders; this does not change internal resolution.

**Scaling filter** selects **Pixelated** (default, sharp pixels) or **Smooth**
(GDI HALFTONE, softer scaling). It applies immediately and is saved in NVRAM,
including restoration after F12. It changes final window scaling only, not
HRFix's map scaling or internal resolution. Smooth can blur text and costs
more time at large output sizes. Both GDI and scaled DirectDraw presentation
use the selected filter; if a DirectDraw surface cannot expose a DC, the
loader logs a warning and uses native Blt. Older DLLs disable the choice.

**Render resolution** changes HRFix's internal `width` / `height`, including in
borderless mode. **Map size** defaults to **Match render resolution**, preserving
normal HRFix behavior. **Original 640x480** keeps the original camera/view area
and stretches the map viewport (tiles, characters, parallax) to the render size.
Pictures and UI in other viewports retain the higher internal resolution.

Both HRFix options apply after closing F10 on the map or title screen with the
updated DLL and scripts. The loader releases the old scene/tilemap and renderer
jobs, applies the resolution and logical map size, clears image caches, recreates
the scene and restores the renderer mode. Game objects and player coordinates
are preserved. Other scenes disable these choices until returning to map/title.
Older DLLs save changes for a full game restart. F12 cancels pending menu changes.
The native loader merges only `width`, `height`, and `hrfix_map_original_size`
into the latest `mod_loader.json`; other config fields remain intact.
These options require HRFix. Use the updated native DLL and scripts together.

This requires the updated native DLL, `1 - ModLoader Core.rb` and the framework directory.
The engine's exclusive fullscreen requests are kept windowed; use the Display
tab to switch presentation modes. No fullscreen hotkey is assigned by default.
An optional Ruby script can register one through the shared hotkey registry:

```ruby
ModLoader::Hotkeys.register(:display, :key => 0x7A, :capture => :menu) do
  ModLoader::Display.toggle
end
```

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
| `ModLoader.configure_display(mode, width, height, scaling)` | Queue window presentation for the next frame: mode `0` = windowed, `1` = borderless; `0, 0` uses game size; scaling `0` preserves aspect ratio, `1` stretches. Returns whether the request was accepted. Prefer `ModLoader::Display` for persisted settings |
| `ModLoader.hrfix_settings(pending)` | `[width, height, original_map_size]`: active startup settings (`false`) or saved settings for the next start (`true`) |
| `ModLoader.save_hrfix_settings(width, height, original_map_size)` | Save HRFix settings for restart; returns `false` on invalid sizes or write failure. Does not alter the current scene |
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

### Menu backgrounds and transitions

`998 - MenuRendering.rb` adds two saved controls under Display -> Rendering:

- **Fast menu blur** (default ON): RGSS-compatible 3x3 blur for `SceneManager.snapshot_for_background`, at full resolution. Ordinary `Bitmap.blur` calls retain the engine path. The native kernel preserves edge replication, alpha and one final integer division, and shares the ViewportEffects worker pool. It remains available without viewport effects and runs inline then.
- **Menu transitions**: Normal (default), Fast (half frame count, rounded up), Off. This applies to ordinary menu crossfades and returns to map/title. Masked battle/event transitions, explicit zero-duration setup calls and map fade-in after loading retain their timing. This changes animation duration rather than the native transition renderer.

`ModLoader.menu_bitmap_blur(bitmap)` changes an exact live Bitmap in place, notifies the engine and invalidates renderer cache versions. It returns false without changing pixels for unsupported objects, allocation failure or the temporary output cap of 64 MiB; the Ruby facade then uses the original blur. Output plus per-band unrounded row sums are temporary and released after the call, additional to the renderer budget. F12 clears temporary scene-routing state and keeps the saved choices.

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
