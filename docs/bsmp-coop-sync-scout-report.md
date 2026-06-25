# BSMP Co-op Sync — Game-wide Scout Report

Result of the game-wide scout (run per `bsmp-coop-sync-audit.md`). Eight parallel
agents combed: switches by id range (1–250 / 251–500 / 501–1000 / 1001–1700),
all named variables, item/gold-granting common events, and player-triggered
`BattleProcessing` map events (maps 1–200 / 201–367).

**Nothing here is applied yet.** Each bucket has a high-confidence batch (safe to
add) and a NEEDS-HUMAN list (a real decision). Verify-flags at the end are gate
mismatches that must be checked before adding.

Scope combed: 1999 switches (801 named), 1499 variables (~260 named), 1699 common
events (96 with grants), 367 maps (183 with `BattleProcessing`).

---

## 0. TL;DR — highest-value findings

1. **`CE33` (取回遗失的魂 / lost-soul recovery)** is broadcast → every peer's death
   dupes the recovered souls to everyone. Called from ~200 maps. **Top priority** →
   `PERSONAL_COMMON_EVENT_IDS`.
2. **A whole boss-kill flag family** (id 1097–1444) follows the *exact* pattern of the
   already-shared 杀害/监禁 roster (init-cleared on page 1, set on defeat, gate later
   pages). ~58 flags, high confidence → `SHARED_SWITCH_IDS`.
3. **Existing READY_GATE entries 54 / 88 (and maybe 181) gate only the FOG events, not
   the embedded battle events** — the same Map54 double-battle bug, still live. Fold the
   battle events in. (Confirms & expands task #17: Map54 boss is events **10, 43, 51**.)
4. **~21 more player-triggered boss encounters** are ungated → double-battle risk.
5. **Bonfires** (1438/1442/1443/1444), **area unlocks/doors/passages** and the **ferry
   dock cluster (90–96)** are clean world-progress switch adds.
6. **World-collectible/kill COUNTER variables** (souls-collected, mobs-killed, candy
   picked) CANNOT be fixed by absolute-broadcast sharing — each peer increments
   independently and last-writer-wins loses the other's. Needs a different mechanism.
7. **Do NOT share** NPC battle-assist switches 901–908 (party composition doesn't sync —
   would claim an ally that only joined on one peer) or ability unlocks 371/372
   (per-player by design).

---

## 1. `SHARED_SWITCH_IDS` — high-confidence additions

Copy-paste list:
```
60, 64, 73, 75, 80, 88, 90, 91, 92, 93, 94, 95, 96,
306, 318, 322, 323, 324, 348, 373, 378, 379, 393, 396,
556,
1004, 1041, 1042, 1043, 1044, 1045, 1081, 1082, 1083, 1085, 1097, 1110,
1116, 1117, 1123, 1124, 1125, 1127, 1130, 1138, 1149, 1150, 1151, 1152,
1157, 1164, 1165, 1166, 1167, 1168, 1175, 1176, 1187, 1188, 1189, 1190,
1192, 1218, 1219, 1236, 1409, 1411, 1413, 1415, 1416, 1417, 1418, 1419,
1420, 1430, 1431, 1432, 1433, 1437, 1438, 1442, 1443, 1444
```

Class breakdown:
- **Cross-map story gates (1–250):** 60 (flower-sea guardian defeated), 64 (tent info),
  73 (rescue girl), 75 (girl death), 80 (cursed-abyss beast), 88 (crystal-stone info).
  Strongest of the low block — written on one map, read on another.
- **Ferry dock unlocks 90–96** (弗洛伊德商业区 … 翡翠之桥东岸): travel-network world
  progress; read by the (personal) ferry CE88. 97/98/99 unused this build but harmless
  to add for future-proofing.
- **Boss-defeat / story / area-unlock (251–500):** 306 Sothsera, 318 Father Skor,
  322/323/324 Evanora apprentice/trial chain, 348 Lake Lord, 373 Soul-Draining Tree,
  378 greed ring obtained, 379 warehouse rope-ladder, 393 Fish-Horse-Head, 396 Nadia
  scroll (cross-map, next to already-shared var272).
- **556** Tamira cooperation-1 quest gate (501–1000; rest of that range's kill/imprison
  roster is already fully covered — verified no misses).
- **Boss-kill / story / unlock block (1001–1700):** the big family — train conductor
  (1116), Fetik (1117), wriggler/crow/marmot/rabbit bosses, Bone Hunter (1149),
  Butchers (1150/1151), Siren Head (1219), Munchkin King (1175), Scarecrow (1409),
  Celia/Grau route flags (1164–1168, 1413–1430), Sanctum chain (1417–1420), plus
  **bonfires 1438/1442/1443/1444**, **area passages 1041–1045**, **doors 1081–1083**,
  NG+ unlock 1004, collab-class 1085.

---

## 2. `SHARED_SWITCH_IDS` — NEEDS-HUMAN

| id(s) | name | the question |
|---|---|---|
| 68, 82, 83, 86, 89 | boss-defeat / quest flags, **read same-map only** | does the existing self-switch sync already keep the non-owner's map correct, or must the flag share too? Decide alongside that boss's READY_GATE entry. |
| 343, 345, 358, 377, 394(+395), 500 | boss-kill / ending / "has-imprisoned" meta | verify each is a *persistent* record, not a per-encounter spawn toggle. 358 = King Nom final kill (his part-flags 359–361 are per-fight). 500 has no write-site found. |
| 338, 342 | Vera death / alive (NPC fate pair) | same class as the shared kill roster — share if Vera's fate must agree across peers. |
| 341 | village church door | area-unlock vs recomputed gate — share only if the door state must match. |
| 1410, 1412, 1434, 1436 | beast-Scarecrow / "kill" / black-distortion appear+defeat | likely per-encounter LOCAL; confirm none latch a persistent post-battle map page. |
| 1192, 1194 | Moko merchant killed / Dorothy imprisonment | NPC-removal world facts — most warrant the kill/imprison class; quick human look. (1192 already in the share list as high-confidence; 1194 left out.) |
| 1423–1427 | boss transform stages 1–5 | live in **Troops.txt** = per-battle; host runs the authoritative fight → **LOCAL** unless a stage latches a persistent page. |
| 901–908 | NPC battle-assist (Klein/Nancy/… join) | **keep LOCAL until party-composition sync exists** — the switch says "ally present" but the `ChangePartyMember` only ran on one peer. |
| 1050–1052 | area shop-open flags | shops are personal; share only if shop-NPC *visibility* must agree. |

**Explicitly LOCAL by design (do NOT share):** 371/372 (rabbit-jump / marmot-burrow
ability unlocks — each player earns their own), the bonfire "usable" block 101–172
(derived UI; real state is the bonfire self-switch, already synced), weapon-existence
201–250 and upgrade-menu 254–300 (per-player inventory recompute), the roaming-invasion
boss family 401–404 / 441–450 (re-armed every map-setup by CE5/CE10; presence already
syncs via MOB_ERASE + self-switch), sex-scene record flags 601–700 (per-player history).

---

## 3. `SHARED_VARIABLE_IDS` — high-confidence additions

Idempotent **absolute** story/scene/sidequest stage markers (same shape as the
already-shared var272). Safe because the broadcast carries the absolute value.
```
36, 59, 77, 78, 79, 80, 82, 84, 85, 86, 88, 89, 91, 92, 93, 99, 100,
210, 215, 217, 218, 219, 220, 250, 266, 268, 270, 271, 273, 274, 276,
277, 281, 282, 286, 289, 290, 297, 298, 299, 1401, 1404
```
Highlights: **36** (☆main-story progress) and **59** (☆world-exploration progress) are
the two central monotonic story counters gating NPC dialogue tiers and map content.
The rest are per-NPC/sidequest scene stages (Klein/Nancy/Ain/Vera/Gertruda/Evanora/…),
250 (demo cleared), 274 (Flower-Court teleport unlock).

> Caveat for 77, 100, 268, 270: these MIX `+=1` with absolute sets. Listed as share
> because the stage-set is the gate, but verify the `+=1` sites are single-fire/gated
> before deploying (a +=1 that can fire on both peers double-counts).

---

## 4. `SHARED_VARIABLE_IDS` — NEEDS-HUMAN (the counter problem)

These are **counters each peer increments independently** (kills, collectibles, turn-ins,
trust-by-talking). Absolute-value broadcast = last-writer-wins → it LOSES or double-counts
the other peer's increments. Sharing them as-is is wrong; they need a different mechanism
(host-authoritative tally, or sum-deltas, or leave personal).

| id | name | why it's hard |
|---|---|---|
| 1032 | Candy-Moko progress (world-wide collectible) | strongest case — each peer picks distinct candies; absolute broadcast loses the other's. |
| 70 | Dorothy trust (gained by talking) | both talk independently; want max, not last-write. |
| 87 | Ain commissions completed | quest turn-in counter. |
| 265 | Greed-Ring count | collectible. |
| 256 | Isabella encounter count | per-player encounters. |
| 1014, 1028 | Hound / twisted-man kill counters | independent kills must sum. |
| 1021, 1025, 1026, 1034 | clue / supply / chest-discovery counters | collectibles. |
| 284, 1402 | dwarf-progress / Chittenango — high-freq `+=1` | look like footstep/exploration counters → probably LOCAL; confirm. |
| 1031 | shop progress | personal merchant unlock vs world — decide. |

---

## 5. `PERSONAL_COMMON_EVENT_IDS` — high-confidence additions

CEs that GAIN items/gold and are personal transactions (would dupe via the loot
broadcast). `ChangeItems([id, OP, …])`: OP 0 = gain, OP 1 = lose; souls = gold.
```
4, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 33, 35,
61, 62, 63, 80, 89, 96, 97, 98, 131, 207, 208,
232, 233, 234, 235, 236, 237, 238, 240,
509, 514, 519, 520, 535, 536, 541, 542, 545, 908, 1014, 1015, 1016
```
- **CE33** — lost-soul recovery (per-player bloodstain), the critical one.
- **20–30, 96–98** — `魂+N` soul-grant consumable items.
- **232–240** — resin/ammo replenish item-uses.
- **519/520/535/536/541/542/545** — loot bags / lockets / consumable containers.
- **61/62/63** — beacon-item refunds on cancel (var48 already shared).
- **509/514/207/208** — crafting/synthesis.
- **908** — Betsy oath fish-gift.
- **89** — backup ferry (duplicate of CE87; child CE88 inherits the flag).
- **18/131** — NG+ wipes (all LOSE; include only for defensive coverage).

Already personal (ShopProcessing — do NOT list): CE 83/84/85/86, and the shop branches
of 902/910/911/903.

**Separate question — death-handler clones.** `CE12` (death) is already in
`SHARED_COMMON_EVENT_IDS` (mirrored + loot-local). It has boss-specific clones with the
same body (Estus refill + death-token): **60, 78, 125, 525, 544**. If these ever run on
one peer without being loot-local, their grants dupe. Decide whether they belong in
`SHARED_COMMON_EVENT_IDS` like CE12 (mirror), not PERSONAL.

---

## 6. `READY_GATE_EVENTS` — additions & gate fixes

### 6a. Fix existing gates that cover only the FOG, not the battle (the Map54 bug)
- **54** — gate is `[[32,33,34]]` (fog) but the scarecrow boss is events **10, 43, 51**
  (troop 716/717). Make it `54 => [[32,33,34], [10,43,51]]`. (This is task #17, expanded.)
- **88** — gate is `[55]` but 7 sibling approach tiles of the SAME Captain Bok fight are
  ungated: 40, 43, 52, 67, 68, 69, 70. Make it `88 => [[40,43,52,55,67,68,69,70]]`.
- **181** — gate `[[4,5,6]]` is the fog; the battle events are 8/9/10 (troop 704/705).
  **Verify** the same fog-vs-battle gap.
- **220** — gate parks on ev**31** (a cutscene that only sets var271); the actual battle
  is ev**12** (troop 515, event_touch). Peers sync at the cutscene then each touches
  ev12 → double battle. **Verify**, likely `220 => [31, 12]`.
- **243** — gate lists ev3 but the 301 (troop 726) is on ev**4**. **Verify off-by-one.**

### 6b. New ungated player-triggered boss encounters (double-battle risk)
Maps 1–200:
```
10  => [16],                          # Ghost Train Conductor (troop 632) — add to existing [11]
20  => [[7,14,15]],                   # Talking Flower (716)
21  => [7],                           # Talking Flower (716)
52  => [28],                          # Grau (720, sw1169)
58  => [1],                           # Tu Shasha (532)
112 => [20],                          # Scarlet (703/702)
155 => [7],                           # Klein phase 3 (712–714)
```
Maps 201–367:
```
210 => [3],    # Nancy covenant boss (707)
235 => [1],    # Iron Captain Fett (520)
242 => [10],   # Evanora boss (728/727, sw322) — distinct from the Map243 train Evanora
271 => [10],   # nightmare-spirit (651, sw403)
316 => [21],   # thought-projection (618, sw449)
318 => [19],   # Priest Skor (521)
319 => [26, 37], # Meiko boss (504) — two trigger pages
324 => [19],   # Grau (724, sw338)
329 => [35],   # Celia boss (718/719) — distinct from the Map44 Celia
332 => [9],    # Lord of the Lake (730)
341 => [2],    # thought-projection (630, sw441)
350 => [18],   # thought-projection (603, sw447)
```

### 6c. Borderline / verify before gating (do NOT add blind)
- `137 => [53]` Killer Crab (escapable mini-boss) — gate if story, leave if respawning.
- `80 => [99,100,123–126]` little-girl mugging (optional, escapable) — probably leave.
- `134 => [6,13,14]` provokable thug brawl (optional) — probably leave.
- `353 => [14]` / `217 => [24]` — single non-boss troops, no cutscene — scripted ambush
  or trivial? confirm.

### 6d. Out of scope here — autorun/parallel bosses
Several bosses are autorun/parallel, not player-triggered (map11 ev2, map21 ev3 Lord of
Decay, map42 ev68, map59 ev22, map82 ev101/113/115/116, map92 ev1 Michael, map93 ev48,
map95 ev41, map111 ev75, map177 ev40 BB). These don't sequentially double-fire, but a
guest whose autorun is suppressed SKIPS the fight — a separate `SHARED_CUTSCENE_EVENTS` /
autorun-suppression audit, not READY_GATE.

---

## 7. Cross-cutting notes & caveats

- **Boss-kill flags = high confidence**, they mirror the existing roster pattern exactly.
- **Counter variables are a genuine gap** (§4) — sharing the absolute value is wrong for
  per-peer-incremented tallies. Worth a dedicated design pass.
- **Party-composition does not sync** — so NPC-assist switches (901–908) and any flag that
  implies an actor was added must wait for that, or they desync.
- **Self-switch sync already covers** a lot of "same-map boss aftermath" — several
  NEEDS-HUMAN same-map flags may not need sharing at all; decide per boss.
- The scouts grep-classified by name + usage and were deliberately skeptical; the
  high-confidence lists are conservative. The NEEDS-HUMAN and verify items are where a
  human (or a focused follow-up) should look before shipping.
