# BSMP Multiplayer — Design Spec

Living design document for the BSMP Steam P2P multiplayer framework. Captures the
agreed architecture and the planned subsystems. Code lives in
`mod_loader/scripts/1200-1240 - BSMP *.rb` (+ `1290` test ghost) and the native
transport in `src/ModLoader/Hooks/SteamSupportHooks.cpp`.

Status legend: **[done]** shipped · **[planned]** agreed, not built · **[open]**
undecided.

---

## 1. Goals & non-goals

- Friends-only co-op (Souls/Terraria vibe): join a friend's world, fight together.
- NOT: dedicated servers, anti-cheat, massive player counts, competitive integrity.
- Acceptable: trust between peers (friends-only), host-ends-session on host leave.

## 2. Architecture backbone

- **Topology:** P2P over a Steam lobby. Lobby owner = **host**, acts as a relay
  star: clients send to host, host rebroadcasts to everyone else (rewriting
  `from_id` to the real sender). Not dedicated, not full mesh. **[done]**
- **Authority — two models coexist:**
  - **Movement = sender-authoritative.** Each peer owns its own avatar; the relay
    forwards to all-except-sender. `from_id` = owner. **[done]**
  - **World / events / battle = host-authoritative.** A guest never mutates shared
    state directly — it **requests**, the host decides (rolls, flips flags) and
    **rebroadcasts the fact from its own `from_id`**. **[planned]**
- **"You join the host's world."** The host's save is canonical for the session;
  guests are visitors. Avoids live save-merge conflicts. **[planned]**
- **Determinism is avoided.** Never independently simulate non-deterministic RPG
  Maker systems (battle RNG, random event movement, parallel events) on each
  client. One owner decides, the result is broadcast. **[principle]**

## 3. Transport

- **BasicNetworkPacket** (native): `magic | type | from_id(u64 LE) | data`.
  Reliable, ordered via Steam channels. **[done]**
- **Compression:** zlib (RGSS3 ships `Zlib`). Only for **large** payloads — small
  movement packets (`"4"`, `"12;15"`) would grow under deflate. **[done]**
  - Framing lives in Ruby, not native: `BSMP::Wire` prepends a 1-byte flags header
    to `data` (`bit0 = compressed`), so the C++ packet stays an opaque blob and more
    flag bits can be added later. `pack` deflates only above a ~256 B threshold and
    only if it actually shrinks; `unpack` reverses it.
  - Applied ONLY at the true wire boundary — `Wire.send_framed` on send (builds a
    framed copy, never mutates the caller's packet), `Wire.unpack` in
    `Client/Server#on_packet_read` before dispatch. Locally dispatched packets
    (`send_client_joined/leaved`, test ghost) stay plaintext. The server relay
    unpacks once on read and re-frames per hop.
  - Native ingest made binary-safe: `BasicNetworkPacket#data=` / `initialize` now
    read the Ruby string by length (`rb_str_value`) instead of as a C-string, and
    `rb_str_value`'s embedded-string branch reads `RSTRING_EMBED_LEN` from the flags
    instead of `strlen` — otherwise a leading `0x00` flag byte truncated the payload.
- **No Marshal over the wire.** `Marshal.load` of peer data is an RCE vector and
  version-brittle. Use explicit compact formats (see World). **[principle]**
- **Anti-echo:** when applying a received change, never re-broadcast it (guard
  flag), mirroring the `from_id` relay rule. **[principle]**

## 4. Handshake [done]

Runs at lobby join, **before** admitting the guest / sending the world.
Implemented as `BSMP::Handshake` + the Client/Server join flow: guest sends
`HELLO` on lobby enter; host validates and replies `WELCOME` + `WORLD_SNAPSHOT`
or `REJECT{reason}`; admission (client record + join broadcast) is deferred until
a valid HELLO. Control packets are point-to-point and never relayed. Validation
logic is covered by `bsmp_test_handshake`.

- `Hello { bsmp_protocol_version, accepted_versions, game_id/title, data_hash, mod_manifest }`.
  - `data_hash`: hash of `$data_*` / scripts so both have compatible content
    (mods change the database — must match).
- **Version negotiation, not exact-match.** Each side declares its own version
  **and** the peer versions it accepts (a range/set, not a point). Verdict needs
  **mutual** acceptance: host accepts the client's version AND the client accepts
  the host's (the client sent its accepted set, so the host checks both in one
  shot). Semver rule of thumb: same MAJOR required (breaking), MINOR/PATCH flexible
  above a declared minimum. A range is less to maintain than an explicit set.
  - Separate axes: **protocol** (wire format, strict) vs **content/mod** version
    (`data_hash`, ~binary compatible-or-not) vs mod-loader version.
- **Decided reject rules:**
  - **MAJOR mismatch → REJECT** (hard, breaking wire change).
  - **MINOR:** accepted iff mutually in range (`ACCEPTED_MINOR_MIN..MAX` on both
    sides); divergence inside the accepted range is fine (log only, no reject).
  - **game (title) mismatch → REJECT** (different game/content entirely).
  - **`data_hash` mismatch → REJECT**, but gated by `Config::CHECK_DATA_HASH` so it
    can be switched off when peers knowingly run differing mods/database.
  - `data_hash` = `Zlib.crc32` over a local `Marshal.dump` of the gameplay-relevant
    `$data_*` (actors/classes/skills/items/weapons/armors/enemies/troops/states/
    system/common_events) — Marshal is used **locally only** (never loaded from a
    peer), the wire carries just the integer.
- Host validates → `Accept { world snapshot follows }` or `Reject { reason }`
  (reason surfaced to the client for a useful message).
- Also the place to negotiate optional feature capabilities.
- **World re-adoption on save-load (`WORLD_REQUEST`).** A guest can accept the
  handshake while still at the title/load menu, so the WELCOME-time `WORLD_SNAPSHOT`
  may arrive before any game is loaded (`World.ready?` false → `World.load` skips
  it). And any `DataManager.load_game` replaces our world with the *save's*. So:
  - The client **caches** a snapshot blob (`@pending_world`) and applies it once
    `World.ready?`, as a best-effort fast path.
  - The authoritative trigger is a **`DataManager.load_game` / `setup_new_game`
    hook** that **blocks** on the sync (`Client#sync_world_blocking`): it sends
    `WORLD_REQUEST` and pumps Steam + packet-read + `Graphics.update` (behind a
    centered `Sync_Window` "Syncing game...") until the snapshot applies, **before**
    the scene transitions to the map — so the map never renders with the stale save
    world. (An overlay driven from `Scene#update` can't help: no scene update runs
    during the load's `Graphics.transition`, which is exactly when the stale world is
    on screen.) Bounded by `AWAIT_TIMEOUT` so a gone host can't hang the load.
  - This is what makes joining-from-menu and **F12** work: F12 raises `RGSSReset`,
    caught in `rgss_main` — it only restarts the scene loop (Audio/Graphics reset),
    **globals and the Steam session persist**, so the guest re-loads a save while
    still connected, and the once-per-client `:ready` transition would never re-fire.
  - Already-in-game lobby joins apply the WELCOME snapshot immediately (a 1–2 frame
    apply that lands with the map/UI, so no blocking needed — the `Scene#update`
    overlay covers it but is effectively invisible).

## 5. World state [planned]

### 5.1 World vs Character split (keystone)

One snapshot format, three uses: **join-dump**, **live baseline**, **session
write-back**.

- **World (shared, host-canonical):** `$game_switches`, `$game_variables`,
  `$game_self_switches`, map/event state, progress bits of `$game_system`.
- **Character (personal, never overwritten):** each player's `$game_party`
  (actors, levels, inventory, gold, equipment), `$game_actors`.

### 5.2 Serialization — `BSMP::World` **[done]**

- **No Marshal.** Bit-pack switches (1 bit each), sparse variables (only non-zero,
  `varint index + tagged value`), self-switches as the `true` `(map_id, event_id,
  ch)` facts. Version-tagged (`FORMAT`), all ints LEB128 varint. zlib via the
  transport once over threshold.
- **Variable value codec is recursive & primitive-only:** `Integer / String /
  Array / true / false / nil / Float` (BS2 actually uses Array-typed variables —
  e.g. vars 1001-1009). Decoding constructs only plain primitives (no object
  instantiation from peer data) → RCE-safe, unlike `Marshal.load`. Unknown classes
  (Hash / Symbol / custom) are logged and stored as nil.
- **Apply = full replace** (host world is canonical): switches overwritten
  wholesale, variables reset to 0 then re-applied (so a guest's stray vars — incl.
  Array vars — don't survive), self-switches cleared then re-set; writes go through
  the public `[]=` so `need_refresh` fires.
- **Measured size (BS2):** ~19 KB raw → **~0.85 KB on the wire** after zlib (~4%;
  the big Array vars compress hard). Sub-1 KB, one-shot at join — negligible.
- Verified by `bsmp_test_world` (dump → mutate → apply → re-dump must be
  byte-identical).

### 5.3 Live sync — host-authoritative facts [decided]

Do **not** mirror raw switch/variable writes globally — that desyncs guests'
event interpreters mid-page and double-fires autorun/parallel cutscenes. The
design is two layers tied to one marking.

**Marking — what counts as "shared":**
- **self-switches: ALL shared**, no tagging. They're the chest/door/NPC progress
  backbone and almost always safe as facts.
- **switches / variables:** Config reserved **range(s) + explicit allowlist**
  (`SHARED_SWITCH_RANGES/IDS`, `SHARED_VARIABLE_RANGES/IDS`). Starts empty, grown
  as real flags are identified. Predicates `shared_switch?/shared_variable?`.

**Flag layer — host-authoritative (intent → fact) [done, 3a]:**
- **Host:** a synced-flag write (its own world logic) → apply locally + broadcast
  the fact to all.
- **Guest:** a synced-flag write (from a guest-side world event) → send an
  **intent** to the host, not canon locally; host validates, applies, broadcasts;
  guest applies on receipt. May apply **optimistically** for snappiness — the
  host's fact is canonical and reconciles on conflict.
- Anti-echo guard (`$bsmp_applying_fact`) so applying a received fact never
  re-broadcasts / re-intents. Hook `Game_Switches#[]=` / `Game_Variables#[]=` /
  `Game_SelfSwitches#[]=`, acting **only** on the shared set.
- **Personal effects (party/inventory/gold) are NOT routed through the host** —
  owner-local (two-tier authority). A guest opening a chest = host-auth self-switch
  (intent) **+** local personal loot into its own `$game_party`.

**Event layer — host runs world cutscenes [done, 3b]:**
- A guest **suppresses an autorun/parallel page iff its activating condition
  references a synced flag** (shared switch/var, or any self-switch). World
  cutscenes run only on the host; their outcome flags arrive as facts.
  Unconditional / local-switch autorun still runs on guests.
- **Cross-map is the easy case:** shared switches/variables are global and
  self-switches are keyed by `map_id`, so a guest on another map just applies the
  deltas; suppression only ever concerns the guest's **own current map**.
- Mandatory "everyone must attend" moments are **not** raw autorun — they're
  explicit sync points (boss-gate, section 8).

### 5.4 Persistence (equal progress for all)

**Storage model: Terraria, not Minecraft [decided — team consensus].** Each player
stores their **own character locally** (own save); the host stores only the
**world** (shared progress), NOT guests' character data. (Minecraft's model — the
server/world holding every player's data — was considered and rejected.) So a guest
brings its character each session and the host never persists foreign characters —
simpler for the host and consistent with the World+Character split.

- During session: host world canonical, synced live (guests hold a mirror).
- On **session end** (host graceful leave or guest leave): each player writes
  `host world` + `own character` to a **dedicated co-op save slot**.
- Result: everyone keeps equal world progress + their own leveled character.
- Caveat: join adopts the host world (your own world for that slot is replaced
  for the session; branching flags don't max-merge) → use a separate slot.

**Loading a save mid-session (guest) — Terraria model [decided].** A save is
conceptually two things, mirroring the two-tier split: a **character** (party,
actors, levels, inventory) and a **world**. A guest loading a save while connected
takes only the **character** and **joins the host's world** — exactly Terraria's
"pick a character, enter someone's world." RPG Maker saves are monolithic, so we
impose the split on load: after the normal load, **keep the loaded
`$game_party`/`$game_actors`, discard its world, re-adopt the host's world
snapshot**; position resolves by same map-id (or respawn near the host if that map
isn't valid). The guest never unilaterally replaces the shared world.
- Implementation: hook the load path → if connected as guest, after load request a
  fresh `WORLD_SNAPSHOT` (or re-apply the last one) over the loaded save's world.
- Edge: the half-state window (loaded world before re-sync) — apply the snapshot
  before the first frame renders / before re-announcing.
- Fallback only if a clean character-extract proves unreliable: **block** load while
  connected (prompt "leave the session first").
- Going to **Title** = leaving the world = leaving the session (clean lobby leave).
- **Host** loading a save mid-session changes the canonical world → host re-broadcasts
  the new world snapshot to all guests (or is blocked); host case is rarer, defer.
- Built together with the co-op save subsystem (build-order step 5) — same machinery.

## 6. Events [planned]

Events split by **ownership**, mostly resolved via **self-switches**:

- **Autonomous / moving (enemies, random NPCs):** suppress the client's move-route
  processing; host drives their positions, broadcast like remote players —
  **reuses the existing interpolation** (a mob = "remote character driven by
  host"). Only movers are host-positioned. **[done — v1, untested]** Implemented in
  `1247 - BSMP Mobs.rb` + the host broadcast in `1240`:
  - A mob = a `Game_Event` whose active page has `@move_type != 0` (random/approach/
    custom). We puppet the **real event** (not a ghost sprite — the game already
    draws it, and graphic/page/passability stay correct for free; page changes
    follow from the synced self-switches, so only position needs the wire).
  - Host: every `MOB_SYNC_INTERVAL` (4) frames, broadcast `MOB_SYNC` =
    `map_id;id,x,y,dir;...` for all movers on its map — skipped when no remote
    player shares the map. Guest on that map: `Game_Event#update_self_movement`
    returns early (`bsmp_puppet?`) and `bsmp_apply_sync` glides/snaps to the host's
    position (mirrors `Player_Character#network_moveto`).
  - **Authority is per-map** (`BSMP.host_here?`): mobs are the host's only on the map
    the host occupies. A guest alone elsewhere simulates its mobs locally (no one to
    desync against). Known gap: two guests sharing a map the host is absent from will
    diverge — deferred (rare; no per-map authority election in v1).
  - **Triggers/battle untouched** (step 6): a puppet mob can still touch-trigger a
    guest's own local encounter for now.
- **Interactive static (chests, NPCs, doors):** keep client-side (positions are in
  map data, identical for all); sync only the **state change** (self-switch) as a
  host fact.
- "Server's view of events" = **moving positions + self-switches**, not all state.

## 7. Loot [done — v1]

- **Instanced loot** (personal-loot, Diablo-style): opening a chest syncs its
  self-switch (open for all), and **each player receives their own copy** into
  their own `$game_party`. No grief, simplest.
- **v1 (`1246 - BSMP Loot.rb`):** hook interpreter commands 125/126/127/128
  (gold/items/weapons/armors). A positive gain broadcasts `LOOT_GAIN` and each peer
  grants its own copy by **running the real command on a throwaway interpreter** —
  so the game's own item-get popup and any other `command_*` mod fire as if the
  event granted it locally. Sender-broadcast with an anti-echo guard
  (`$bsmp_applying_loot`); the chest's self-switch sync prevents re-opening, so no
  double grant. Only gains (not removals); non-event sources (shop/menu/battle) use
  other code paths and stay personal.
- **Later:** host-arbitrated rolls for *random* loot (so everyone rolls the same);
  v1 is deterministic, fine for fixed chest loot.
- (Alternative considered & rejected for co-op feel: first-come — opener only.)

## 8. Boss readiness gate [planned]

Synchronized "all-in" before a boss:

- Small host state machine: `PENDING → collect accepts → ALL_READY → start + lock
  zone for everyone`.
- Players approach the fog, get a challenge prompt, accept; host collects;
  when all accepted → simultaneous transition; on start the host locks the exit
  (barrier/switch) for all → "everyone gets stuck in together".
- **[open]** edge cases: someone declines / walks away / disconnects during the
  vote → abort the challenge or proceed without them?

## 9. Battle (co-op ATB) [planned]

Biggest, riskiest epic. **Host-authoritative**, NOT lockstep.

**Integrated-server model (Minecraft-style).** Split battle into a **BattleServer**
(authority: ATB ticking, RNG, AI, action resolution, broadcasts results) and a
**BattleClient** (the `Scene_Battle` view: render + own-turn input). The host runs
BattleServer **plus a local BattleClient**; guests run only BattleClient. The
host's client talks to its server **in-process (loopback)**, guests' clients talk
over the wire — but it's the **same BattleClient code path** both ways, so the
host is never a special case. Lets the client path be tested on the host alone
(like the movement ghost). Define a clean BattleServer→BattleClient event
interface that is either local calls (host) or packets (guests).

- **Host runs the real `Scene_Battle`** and ticks ATB. When an actor's bar fills:
  - host's local actor → host picks command;
  - **guest's actor → host requests "your turn", waits for the command packet,
    executes**;
  - enemy → host AI.
- **Host computes ALL results (damage, hit/miss, RNG, drops) and broadcasts the
  result.** Clients **do not re-roll** — they apply authoritative HP/states/anim.
- **Client battle = mute terminal:** render the scene + supply input for its own
  turn. Cut everything that *decides* (damage calc, RNG, AI, ATB ticking, drops).
- **Joining mid-battle:** needs a full **battle snapshot** (enemies+HP+states, all
  actors+HP/MP+states, ATB fill, turn order), not a delta.
- **Shared battle party:** combined troop-side = actors of all participants;
  `BattleManager.battle_members` must span multiple players (most invasive part).
- **Death-but-in-battle:** a downed player stays spectating until battle ends or
  is revived (prevents double-entry). Handle **disconnect while downed** so the
  battle doesn't hang waiting on a revive of someone who left.
- Phasing: (1) snapshot + join, (2) authoritative action execution + remote
  render, (3) remote-turn input request/response.

### 9.0 Engine map (BS2 custom "71's ATB") — injection points

Studied from the decompile before building. The custom ATB lives in `161 - 71
Scene_Battle.rb` (it **reopens both `Scene_Battle` and `BattleManager`**); the
stock resolve/scene is `116 - Scene_Battle.rb`, `6 - BattleManager.rb`, `23 -
Game_Battler.rb`; AP charging is `165 - Game_Battler フレーム更新.rb`, config
`160 - ATB设定.rb`. Key seams:
- **ATB/AP tick (deterministic, no RNG):** `Game_Battler#ap_gain_point`/`ap_update`
  (165) charges `@ap` to `ATB::MAX_AP` (8000); driven by AGI + states + `FRAME_AP_GAIN`.
  Ticked in `Scene_Battle#battlers_frame_update` → `frame_update` inside the charge
  loop of `start_party_command_selection` (161). **Mute client suppresses this.**
- **Turn-ready / order:** `BattleManager.action_battler` (161) = `[act_forced,
  act_chant, input_battler].compact[0]`; `input_battler` = first battler with `ap >=
  MAX_AP`. Single funnel for "whose turn".
- **Command input:** `Scene_Battle` window handlers (116): `command_attack/skill/
  guard/item` → `BattleManager.actor.input` (`Game_Action`); target via
  `on_enemy_ok`/`on_actor_ok`.
- **Action resolution / RNG boundary (host authority):** `Scene_Battle#invoke_item`
  (116) → counter/reflect RNG; `Game_Battler#item_apply` (23) → hit/evade/crit +
  `make_damage_value`/`apply_variance` RNG → `execute_damage` (HP/MP). Animations via
  `show_animation`. **Host computes here; client only replays results.**
- **Enemy AI:** `Game_Enemy#make_actions`/`select_enemy_action` (25), RNG-weighted.
- **Main loop:** `Scene_Battle#update` (116) → if `in_turn?` `process_event` +
  `process_action`; then `judge_win_loss`.
- **Members:** everywhere `$game_party.* + $game_troop.*` (`all_alive_members` 161,
  `check_members` 161, `all_battle_members` 116) — the combined-party seam.
- **Win/lose / end:** `BattleManager.judge_win_loss` → `process_victory/defeat/abort`
  → `battle_end(result)`.
- **Net pump:** `bsmp_read_packets` runs in `Scene_Base#update` (1240), so a mute
  Scene_Battle that calls `super` renders (`update_basic`) AND reads packets.

### 9.1b Authority decision [locked 2026-06-20]

After 6.1 wire-tested, the model is locked: **lobby-host authority, ONE global
co-op battle, everyone participates** (combined party vs one scaled troop).
Alternatives considered and rejected:
- **Initiator-authoritative per-skirmish** (each fight run by whoever started it →
  free N-parallel battles, host not overloaded). Clean and cheaper than host-headless,
  but the team chose host+all-join for **balance simplicity** (one party vs one troop)
  and consistency (the mob dies for everyone anyway).
- **Host runs N battles headless** (host's original idea). Needs an instanceable,
  headless ATB engine — extract BS2's heavy custom ATB out of `Scene_Battle` and swap
  `$game_troop`/`BattleManager`/`$game_party` per instance per frame. Huge and fragile;
  the all-join model sidesteps it entirely (one battle, host is a participant).

All-join does NOT foreclose **mid-join by proximity** later: that's a trigger-layer
policy (a guest enters when it walks into the on-map skirmish and gets the current
snapshot instead of the start) — the snapshot + combined-party machinery (6.2/6.3),
built anyway for mid-battle join (§9), already supports adding a participant at any time.

Stats on join (default): **newcomer makes it easier**, no rescale, scale locked at
start (§9.1). Do NOT mid-battle rescale **multi-phase bosses** (HP-threshold phase
transitions would re-trigger); boss-specific handling deferred. Most enemies are
single-phase, so the default fits them.

### 9.2 Build sub-steps (6.1–6.6) + status

- **6.1 Session lifecycle + mute client [done — code, not yet wire-tested].**
  `1250 - BSMP Battle.rb` (+ `BATTLE_START`=24 / `BATTLE_END`=25 in 1200). Host hooks
  `Scene_Battle#start` → broadcast `BATTLE_START`=`"troop_id;can_escape"` and
  `BattleManager.battle_end` → `BATTLE_END`=`result`; both guarded `BSMP.host?` so
  guests never emit. Guest: `on_battle_start` queues `BSMP::Battle.pending`,
  `Scene_Map#update` enters it (`BattleManager.setup` + `SceneManager.call(Scene_Battle)`,
  `can_lose=true`), the transition visuals fire from Scene_Map's terminate hooks;
  `BATTLE_END` → `request_end` → mute `Scene_Battle#update` does `SceneManager.return`.
  Mute scene: `battle_start` only `on_battle_start`s party/troop (no emerge msgs / no
  ATB charge / no command window), `update` = `super` (render + net pump) and nothing
  else (no FSM, no win/lose). v1 pull-in = ALL guests join a host-initiated battle
  regardless of map ("fight together"); guest-touched local encounters still fight
  locally (changed in 6.6). First wire test: guest enters/exits battle in lockstep,
  sees the same enemies (actor side is still the guest's own party until 6.3).
- **6.2 Snapshot + authoritative state streaming [next].** Stream ATB fill, HP/MP/TP,
  states(+turns) and action events (anim/damage/log) so the mute scene animates; full
  join snapshot vs per-tick deltas; capture at the RNG/resolve boundary on the host.
- **6.3 Combined party (guest actor in the fight) [planned].** Guest sends actor
  snapshot; host rebuilds proxy `Game_Actor`(s) and merges so `$game_party.*` /
  `battle_members` span all players. Most invasive.
- **6.4 Remote-turn input [planned].** Host requests a guest's command when its ATB
  fills; guest opens its command window, replies; host validates + resolves.
- **6.5 End / rewards / death / disconnect [planned].** Authoritative win/lose;
  personal reward grants (like loot §7); downed=spectator; disconnect-while-downed
  cleanup so the battle never deadlocks.
- **6.6 Scaling + guest-initiated encounters [planned].** Enemy HP×N / ATB speed
  locked at start (§9.1); change step-4's local guest encounter into a host-auth
  request; settle the pull-in rule (all vs same-map vs proximity).

### 9.1 Balance scaling by player count

Co-op breaks action economy (more attackers per ATB cycle), so difficulty must
scale up. Host-authoritative (host applies it on battle start from the
participant count):

- **Enemy HP ×N** — safest knob; keeps fights from ending instantly.
- **Enemy ATB speed** — ATB-aware lever: more players = more total player turns,
  so speeding the enemy's bar restores turn economy instead of just bloating HP.
- Recommend **combining** modest HP scale (duration) + ATB scale (economy).
- **Mid-battle join** changes the count: **lock the scale at start** (late joiners
  just make it easier) rather than re-scaling live. **[open]** revisit if needed.

## 10. Disconnect / session end [planned]

- **Guest leave:** detected via `on_lobby_chat_update`; host removes them and
  broadcasts. **[done]** Guest persists per §5.4.
- **Host leave = session end** (host-migration is impractical: guests lack the
  host's full world). Host broadcasts a graceful "session over"; guests persist
  (§5.4) then drop to single-player. **[planned]**
- **Disconnect mid-battle:** clean up so the battle never deadlocks.

## 11. Cross-cutting checklist

- [ ] anti-echo guard on every applied remote change
- [ ] single owner per shared change (no double-fire)
- [ ] host-leave = graceful session-end + guest persistence
- [ ] battle-disconnect cleanup
- [x] compressed-flag + zlib threshold in the transport
- [ ] protocol/content version handshake before world transfer

## 11b. Player presence & navigation [planned]

Free roam across any non-progress-gated location (shared world, guests roam
freely). Showing **where** other players are, layered by cost:

- **RPG Maker has no global map coordinates.** Maps are ID'd islands linked by
  transfer events; `MapInfos.parent_id` is editor folders (hierarchy), not space.
  So cross-map "B is north-east of me" can't be computed directly.
**Default plan: 1 + 2.** 3 is optional/future (not essential if names are good).

- **1. Location name in the player list [done].** The player **broadcasts its own
  best name** with `PLAYER_CHANGED_MAP` (`"map_id;name"`): it has its map loaded, so
  it picks `display_name` (lore banner) when non-empty, else
  `$data_mapinfos[map_id].name` (editor name, always set). The viewer just shows the
  received string — no loading peer maps, lore names for free, with a local
  `$data_mapinfos` fallback by id. Shown in the roster's right-hand column.
- **2. Same-map arrow marker [cheap].** When two players share a `map_id` we have
  their `x,y` → a real directional arrow. Intra-map only; positions already sync.
- **3. Cross-map "go here" routing [heavy, optional/future].** No absolute coords — build a
  **connectivity graph**, quest-marker style. Offline/boot: scan every
  `Map###.rvdata2` for Transfer Player (event command code 201, direct target) to
  build `mapA(exit@x,y) -> mapB` edges; BFS from your map to the target's map; the
  first edge says which exit on your current map to head to → drop a marker there,
  recompute on each transfer. Caveats: parse-all-maps cost (cacheable);
  variable-target transfers can't be graphed.

## 12. Already shipped (foundation)

- P2P lobby relay, reliable ordered transport, `from_id` ownership.
- Remote-player sprites, nicknames, position/move/map/speed/character sync.
- **Client-side interpolation** of remote players (target + glide, catch-up,
  smoothing) — reused for host-driven mobs.
- Self-sufficient Steam init + callback pump; null-guarded interfaces.
- `module BSMP` split across load-ordered files; `BasicNetworkPacket` binary-safe.
- **Transport compression** (`BSMP::Wire`, 1-byte flag frame + zlib threshold).
- **Handshake** (`BSMP::Handshake`) + **world dump/apply** (`BSMP::World`).
- **Status panel** (`BSMP::Status_Window`: role / online count / nicknames).
- Test harnesses: ghost (interactive) + `bsmp_test` (handshake + world unit tests).

## 13. Suggested build order

**Wire-verified over a real WAN link:** handshake, world snapshot, presence +
location names, movement/interpolation, join/leave visibility, ping, instanced
loot. (Steam P2P session auto-accept was needed — see §3 / native fix.)

1. ~~**Transport:** compressed flag + zlib threshold (everyone needs it).~~ **[done]**
2. ~~**Handshake** + world **dump** (bit-packed) on join.~~ **[done, wire-verified]**
3. ~~**Self-switch / tagged-progress sync** with anti-echo → unlocks loot, boss gate,
   mob state.~~ **[done]** — 3a flag layer (host-auth facts + anti-echo,
   `BSMP.shared_*` config) and 3b guest-side cutscene suppression (host-owned
   autorun/parallel). self-switch facts wire-verified; cutscene suppression still to
   confirm live. Shared switch/var config starts empty (self-switches already
   shared) — populate as story flags are identified.
   - Plus: **instanced loot** (§7) and the **roster/presence** UI (ping, locations).
4. ~~**Host-driven mobs** (reuse interpolation).~~ **[done — v1, not yet wire-tested]**
   Movers puppeted on guests on the host's map; per-map host authority; triggers/
   battle deferred to step 6. See §6.
5. **Session-end persistence** (write-back to co-op slot).
6. **Battle epic** (phased).
