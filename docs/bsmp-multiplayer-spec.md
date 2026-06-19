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
  movement packets (`"4"`, `"12;15"`) would grow under deflate. Plan: a
  `compressed` flag bit in the packet header + size threshold (~64-100 B); set in
  native `to_raw_data`, transparent to the Ruby layer. **[planned]**
- **No Marshal over the wire.** `Marshal.load` of peer data is an RCE vector and
  version-brittle. Use explicit compact formats (see World). **[principle]**
- **Anti-echo:** when applying a received change, never re-broadcast it (guard
  flag), mirroring the `from_id` relay rule. **[principle]**

## 4. Handshake [planned]

Runs at lobby join, **before** admitting the guest / sending the world.

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
- Host validates → `Accept { world snapshot follows }` or `Reject { reason }`
  (reason surfaced to the client for a useful message).
- Also the place to negotiate optional feature capabilities.

## 5. World state [planned]

### 5.1 World vs Character split (keystone)

One snapshot format, three uses: **join-dump**, **live baseline**, **session
write-back**.

- **World (shared, host-canonical):** `$game_switches`, `$game_variables`,
  `$game_self_switches`, map/event state, progress bits of `$game_system`.
- **Character (personal, never overwritten):** each player's `$game_party`
  (actors, levels, inventory, gold, equipment), `$game_actors`.

### 5.2 Serialization

- **No Marshal.** Bit-pack switches (1 bit each → ~125 B / 1000), int-pack
  variables; self-switches as `(map_id, event_id, ch) -> bool` facts. Compact,
  safe (numbers only), version-tolerant. zlib the whole snapshot (it's large).

### 5.3 Live sync — the softlock trap

Do **not** mirror raw switch/variable writes globally — that desyncs guests'
event interpreters mid-page and double-fires autorun/parallel cutscenes.

- **Classify:** a tagged subset = "shared progression" (quests, bosses) syncs as
  facts from the owner; everything else stays local.
- **Cutscenes/autorun run on ONE** (host or trigger owner); only the **outcome**
  (flag flipped) is broadcast, never "run this on yourselves".
- Hook `Game_Switches#[]=` / `Game_Variables#[]=` / `Game_SelfSwitches#[]=` with
  an anti-echo guard, **only** for the shared-tagged range.

### 5.4 Persistence (equal progress for all)

- During session: host world canonical, synced live (guests hold a mirror).
- On **session end** (host graceful leave or guest leave): each player writes
  `host world` + `own character` to a **dedicated co-op save slot**.
- Result: everyone keeps equal world progress + their own leveled character.
- Caveat: join adopts the host world (your own world for that slot is replaced
  for the session; branching flags don't max-merge) → use a separate slot.

## 6. Events [planned]

Events split by **ownership**, mostly resolved via **self-switches**:

- **Autonomous / moving (enemies, random NPCs):** suppress the client's move-route
  processing; host drives their positions, broadcast like remote players —
  **reuses the existing interpolation** (a mob = "remote character driven by
  host"). Only movers are host-positioned.
- **Interactive static (chests, NPCs, doors):** keep client-side (positions are in
  map data, identical for all); sync only the **state change** (self-switch) as a
  host fact.
- "Server's view of events" = **moving positions + self-switches**, not all state.

## 7. Loot [planned]

- **Instanced loot** (personal-loot, Diablo-style): opening a chest syncs its
  self-switch (open for all), and **each player receives their own copy** into
  their own `$game_party`. No grief, simplest.
- Host arbitrates the roll and applies to the right party/parties.
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
- [ ] compressed-flag + zlib threshold in the transport
- [ ] protocol/content version handshake before world transfer

## 11b. Player presence & navigation [planned]

Free roam across any non-progress-gated location (shared world, guests roam
freely). Showing **where** other players are, layered by cost:

- **RPG Maker has no global map coordinates.** Maps are ID'd islands linked by
  transfer events; `MapInfos.parent_id` is editor folders (hierarchy), not space.
  So cross-map "B is north-east of me" can't be computed directly.
**Default plan: 1 + 2.** 3 is optional/future (not essential if names are good).

- **1. Location name in the player list [cheap].** The player **broadcasts its own
  best name** with `PLAYER_CHANGED_MAP`: it has its map loaded, so it picks
  `display_name` (lore banner) when non-empty, else `$data_mapinfos[map_id].name`
  (editor name, always set). The viewer just shows the received string — no
  loading peer maps, lore names for free, always a fallback. (Resolves the
  editor-vs-lore dilemma.)
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
- Test ghost harness (single-account local testing).

## 13. Suggested build order

1. **Transport:** compressed flag + zlib threshold (everyone needs it).
2. **Handshake** + world **dump** (bit-packed) on join.
3. **Self-switch / tagged-progress sync** with anti-echo → unlocks loot, boss gate,
   mob state.
4. **Host-driven mobs** (reuse interpolation).
5. **Session-end persistence** (write-back to co-op slot).
6. **Battle epic** (phased).
