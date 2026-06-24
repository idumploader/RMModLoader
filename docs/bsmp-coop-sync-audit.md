# BSMP Co-op Event Sync — Audit Log & Scout Briefing

Working document for hardening BS2 (BLACK SOULS 2) co-op against world-state
desync. It does two things:

1. **Catalog** of confirmed un-synchronized events found in playtesting (so we
   don't lose them), with the fix applied or proposed.
2. **Briefing for a scout agent** that will comb the *whole* game and produce a
   summary of switches / variables / events / common-events that still need a
   sync decision.

> Do **not** launch the scout until the user says go.

---

## 1. The BSMP sync "buckets" (how each case gets classified)

Config lives in `mod_loader/scripts/1200 - BSMP Core.rb`, `module BSMP::Config`.
Every world-affecting flag/event belongs in exactly one of these:

| Bucket (Config constant) | Use it for | Effect |
|---|---|---|
| `SHARED_SWITCH_IDS` / `SHARED_SWITCH_RANGES` | global switches that are **world progress** (quest/boss gates, NPC kill/imprison flags, "special items shown") | switch write broadcasts live to all peers. *Self-switches are ALWAYS shared — no list.* |
| `SHARED_VARIABLE_IDS` / `SHARED_VARIABLE_RANGES` | global variables that are world progress (story counters, covenant ranks) | variable write broadcasts the **absolute** value (idempotent; safe for `+=` counters since only the shared hook re-sends) |
| `PERSONAL_COMMON_EVENT_IDS` | common events whose item/gold gains must stay **per-peer** (crafting, ChangeItems "shops", Estus refill) | suppresses the loot broadcast so the grant isn't duped to everyone |
| `SHARED_COMMON_EVENT_IDS` | common events that must be **mirrored** so every peer runs its own copy (death = CE 12) | host running it tells all peers to run it too |
| `SHARED_CUTSCENE_EVENTS = {map=>[event]}` | **autorun/parallel** STORY cutscenes everyone should watch, even though gated on a shared flag | guest bypasses the autorun-suppression AND the event's self-switch latch stays per-peer. **Only for IDEMPOTENT scenes** (dialogue, local transfer, absolute flag sets) — never loot/battle/relative counters |
| `READY_GATE_EVENTS = {map=>[event \| [event…]]}` | **player-triggered** (action/touch) events everyone must reach & confirm before firing — boss fog walls, boss encounters with an embedded `BattleProcessing` | parks the first arriver until all confirm, then all resume together; the battle inside runs once (host-authoritative, others join via BATTLE_START). Prevents **sequential double-execution / double-battle** |
| `CHOICE_GATE_WORDS` | irreversible Show-Choices options (kill / rape) | consensus before the point of no return |

Decision shortcuts:
- Grants items/gold and is a **personal transaction** (craft/shop) → `PERSONAL_COMMON_EVENT_IDS`. (`ShopProcessing`/Scene_Shop is already personal — leave it.)
- Sets a **global switch/var that is world progress** → `SHARED_*`.
- Is an **autorun cutscene** gated on a shared flag that everyone should see → `SHARED_CUTSCENE_EVENTS`.
- Is a **player-triggered boss/fog/encounter** with a battle or one-shot world effect → `READY_GATE_EVENTS`.
- Is **scratch/temp** (random rolls, per-event working vars) → leave it local.

---

## 2. Where to look (data & decompile)

- **Decompiled event scripts** (readable): `D:\Games\bs2_mod_demoV0.49\decompile\`
  - `CommonEvents\CommonEvent<N>.txt`
  - `Maps\Map<NNN>.txt`  (events are labelled `CommonEvent <id>` but they are MAP events)
  - `System\Switches.txt`, `System\Variables.txt`
- **Switches and variables HAVE NAMES.** `System\Switches.txt` and
  `System\Variables.txt` are line-indexed: **line number = id**, the text is the
  (usually Chinese) name. Always resolve and quote the name — it reveals intent.
  Examples: var48 = `星炬波动计数` (beacon oscillation counter), switch20 =
  `时间重叠开启` (time-overlap beacon ON), var272 = `娜蒂雅演出1` (Nadia scene 1).
- **Triggers & page conditions are NOT in the .txt.** To get a page's
  `@trigger` (0 action, 1 player_touch, 2 event_touch, 3 autorun, 4 parallel)
  and `@condition` (switch1/2, variable, self_switch), read the binary map with
  python rubymarshal:
  - interpreter: `C:\Program Files\Python311\python.exe` (has `rubymarshal`)
  - live data: `D:\Games\bs2_mod_demoV0.49\Data\Map<NNN>.rvdata2`
  - working dumper: `…/scratchpad/dump_triggers.py` (loads a map, prints each
    event's pages with trigger + condition). Map files load fine WITHOUT the
    cyclic-link patch (that was only needed for save files). Force UTF-8 stdout.

---

## 3. Confirmed examples (this session)

| # | Where | Problem | Bucket / Fix | Status |
|---|---|---|---|---|
| 1 | Map358 | var272 (rope after fish boss), var48 (beacon counter), switch20 (special items) not syncing | `SHARED_VARIABLE_IDS += 48,272`; `SHARED_SWITCH_IDS += 20` | **Fixed** |
| 2 | Map108 "Veronika" merchant | soul/material→gear crafting (CE 510/511/512/540, via ChangeWeapons/Armor/Items) duped to everyone via loot broadcast | `PERSONAL_COMMON_EVENT_IDS += 510,511,512,540` (CE 84/85 use ShopProcessing → already personal) | **Fixed** |
| 3 | Map358 Event 22 | post-fish "rope ladder" story dialogue (autorun `var272>=1`, sets var272=2 + self-switch A) ran only on the map owner | `SHARED_CUTSCENE_EVENTS = {358=>[22]}` (guest runs the autorun; self-switch latch kept local; var272 stays shared) | **Fixed** |
| 4 | Map54 Event 10 | boss cutscene (player_touch @25,14: dialogues + boss-NPC move-in + `BattleProcessing` troop 716/717). Only the fog tiles (32-34) are gated; Event 10 is NOT. Both peers run it unsynchronized → after the first wins, the second hits its own `BattleProcessing` → **sequential double boss battle** | **Probable:** add Event 10 to the map-54 gate, e.g. `54 => [[32,33,34], 10]`. Needs verify that gating the encounter event (not just the fog) makes the battle fire once. | **Open** |

### Notes carried by these examples
- `set_tone` / `rich_fog` / `end_noise` (CE55, beacon) are **caller-only** screen
  FX — they don't sync and that's accepted (cosmetic). Only the world state
  (switch20, var48) syncs.
- A shared **var set absolutely** (`= const`) is the easy case. A shared `+=`
  counter is also fine because the broadcast carries the absolute post-value.
- The Map54 double-battle is the general hazard for **any player-triggered event
  with an embedded battle that isn't in `READY_GATE_EVENTS`**.

---

## 4. Scout task (run later, on the user's explicit go)

**Goal:** comb the entire game and produce a classified summary of every
world-affecting switch, variable, common-event and map-event that is NOT yet
covered by the Config lists above, with a recommended bucket for each.

Scan:
1. **Switches & Variables** — for each id WRITTEN by an event (`ControlSwitches`,
   `ControlVariables`), decide: world progress (→ `SHARED_*`) or local/scratch
   (leave). Resolve the **name** from System/*.txt. Output: id, name, set-site(s),
   read-site(s), recommendation, whether already in Config.
2. **Common events that grant items/gold** (`ChangeItems`/`ChangeWeapons`/
   `ChangeArmor`/`ChangeGold`) or use `ShopProcessing` — personal transaction
   (→ `PERSONAL_COMMON_EVENT_IDS`) vs genuine world loot (leave to broadcast).
   `ShopProcessing` is already personal — note but don't list.
3. **Map events with an embedded `BattleProcessing` reached by a player-trigger**
   (action/touch) — is the event in `READY_GATE_EVENTS`? Flag every boss/encounter
   that is **not** (double-battle risk). Triggers via rubymarshal.
4. **Autorun/parallel story cutscenes** gated on a shared flag — should they be in
   `SHARED_CUTSCENE_EVENTS` (everyone watches) and is the scene idempotent?

Cross-check against the CURRENT Config lists (read them from `1200 - BSMP Core.rb`)
so already-covered ids are marked "covered", not re-proposed.

**Output:** one markdown table per bucket — `id | name | location | current status
| recommendation` — plus a "needs human decision" section for ambiguous cases
(e.g. a var that's both a counter and a scratch).

**Reminders for the scout:**
- Switches/vars **have names** in `System\Switches.txt` / `Variables.txt`
  (line = id). Always include the name.
- Page **triggers/conditions are not in the .txt** — use rubymarshal
  (`scratchpad/dump_triggers.py`), live data in `…\Data\Map<NNN>.rvdata2`.
- Do **not** propose sharing scratch/temp vars (e.g. CE54 uses var53 for a random
  roll) — only persistent world state.
- Don't re-list ids already in the Config buckets — mark them covered.
