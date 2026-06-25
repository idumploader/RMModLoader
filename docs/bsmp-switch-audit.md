# BSMP co-op switch/variable audit — confirmed findings

Per-switch audit of everything examined directly against the game data (decompile/
Maps, decompile/System/Switches.txt + Variables.txt, Scripts/). This is the
source-of-truth that CORRECTS the earlier scout report
(`docs/bsmp-coop-sync-scout-report.md`), which mis-flagged bonfires and invasions as
"local".

Legend:
- **Decision**: `SHARED` (synced as world progress) / `LOCAL` (per-peer, must NOT sync)
  / `PENDING` (needs one more look).
- **Confirmed**: `yes` = read the real set/read sites; `partial` = page-condition reads
  are stripped by the decompiler, inferred from set-sites + names.
- **Mechanism**: how it is (or should be) synced.

RPG Maker note: `ControlSwitches([id,id,0])` = switch ON, `…,1])` = OFF. ConditionalBranch
`[0,…]` = switch, `[1,…]` = variable.

---

## 1. Bonfires — SHARED via `SHARED_SWITCH_RANGES (101..172)`

The lit/travel network. Real GLOBAL switches, NOT self-switches (scout was wrong).

| id | name (zh) | does | confirmed | decision |
|---|---|---|---|---|
| 101,103,…171 (odd) | `<место>篝火` | bonfire discovered/lit; set by ControlSwitches on the map when reached | yes (e.g. Map173→101, Map032→103, Map014→109) | SHARED |
| 102,104,…172 (even) | `<место>篝火可用` | bonfire available to fast-travel; gates the warp-menu entry | yes (MOVE_LIST visible-switch, `Scripts/_.55.rb`; CE503 story batch) | SHARED |
| 379 | 仓库篝火点绳梯开启 | warehouse rope-ladder at the bonfire | yes | SHARED (IDS, pre-existing) |
| 1438,1442,1443,1444 | 黑渊/坠落之屋/废镇西/地下入口 篝火 | separate higher bonfire block, NOT in MOVE_LIST (vestigial dups?) | partial | SHARED (IDS) — harmless |

Warp menu = `KURE::ShortMove::MOVE_LIST` in `Scripts/_.55.rb`:
`[[name, visible_switch, sel_switch, erase_switch],[map,x,y,dir]]`; all 36 visible
switches fall inside 102..172.

## 2. Roaming invasions — SHARED via `SHARED_SWITCH_RANGES (401..404, 441..450)`

Wandering invader bosses. Appear-switch gates whether the invader SPAWNS (so MOB_ERASE
can't cover it — scout was wrong). Cleared at any bonfire by CE5/CE10.

| id | name (zh) | does | confirmed | decision |
|---|---|---|---|---|
| 401/402 | 恶灵阿尔伯特 出没/消灭 | Albert appears / defeated | yes (Map080) | SHARED |
| 403/404 | 恶灵丽兹波顿 出没/消灭 | Liz Borden appears / defeated | yes (Map271) | SHARED |
| 441/442 | 哭泣天使 出现/击破 | Crying Angel appears / defeated | yes (Map341) | SHARED |
| 443/444 | 异念投影 入侵/狂暴 | Thought-projection invades / frenzy (no kill flag; CE9 toggles) | yes (CE9) | SHARED |
| 445/446 | 雨之嫁衣 出现/击破 | Rain-bride | yes (Map083) | SHARED |
| 447/448 | 深海恐惧 出现/击破 | Deep-sea fear | yes (Map350) | SHARED |
| 449/450 | 死亡预兆 出现/击破 | Death-omen | yes (Map316) | SHARED |

Mechanism notes:
- Armed on the boss's map; appear+kill are GLOBAL ControlSwitches (Map341 sets both 441
  and 442). CE5/CE10 = deactivators (set appear-flags OFF), called from bonfire maps.
- Kill sets the even flag in the on-map IfWin → same as the boss-kill family.

### 2b. Invasion banners (common events, called inline in IfWin)
| CE | name | does | decision | mechanism |
|---|---|---|---|---|
| 75 | ЗЛОЙ ДУХ УНИЧТОЖЕН | victory banner (Albert/Liz) | SHARED | `SHARED_COMMON_EVENT_IDS` mirror — **task #27, pending** |
| 76 | БЕЗУМНЫЙ ДУХ УНИЧТОЖЕН | victory banner (mad spirit) | SHARED | mirror — task #27 |
| 77 | ПРОЕКЦИЯ УНИЧТОЖЕНА | victory banner (projection forms) | SHARED | mirror — task #27 |
| — | appearance announce (Map341 EV004 etc.) | "<boss> появился / ВТОРЖЕНИЕ!!" | SHARED (visual) | NOT SHARED_CUTSCENE_EVENTS (autorun latch IS the shared appear-switch → races). FX-mirror like beacon 1270 — **task #28, pending** |

## 3. Flower-sea (花海) "find the girl" arc

Map072 "迷幻花海" girl arc → Map111 "花海深处" boss. Added to `SHARED_SWITCH_IDS` this session.

| id | name (zh) | does | confirmed | decision |
|---|---|---|---|---|
| 54 | 花海封锁解除 | blockade lifted / passage opens | yes (Map072, 4 sites) | SHARED |
| 61,62,63 | 花海进度1/2/3 | found-the-girl progress | yes | SHARED |
| 63 | 花海进度3 | **also gates Map111 boss pedestal ev13** (CROSS-MAP: set only in Map072:1735, read on Map111) | yes | SHARED (critical) |
| 72 | 花海深处解锁 | depths unlocked | yes (Map072) | SHARED |
| 60 | 花海守护者击破 | Guardian kill → despawns the pedestal | yes | SHARED (already, Core:178) |
| 1130 | 异变之源消灭 | source-of-mutation destroyed | yes | SHARED (already, Core:208) |
| 55 | 花海封锁开始 | blockade START; set ON only in Map093, no explicit read found | partial | **PENDING** (low priority) |

Map111 boss pedestal (READY_GATE `111 => [13]`): appears on switch 63, despawns on 60.
"Columns" = `花海之柱` map self-switches (133 in Map111) → already synced. Pillar-burn
count `var 76 花海之柱燃烧数` is set ABSOLUTELY (76=1/2/3/4/0) and checked `76 == N`; it's
a sequence-state var backed by the pillar self-switches → LOCAL, likely fine (boss gate
is 63, not 76).

## 4. Confirmed LOCAL (do NOT share)

| id | name (zh) | why local |
|---|---|---|
| sw 4 | 魂在该地图 | per-player soul/death marker (where YOUR soul dropped) |
| sw 18 | 状态显示 | UI status-display toggle |
| sw 28 | 幻惑 | per-player illusion-maze state; toggled ON/OFF inside Map072, not read outside |
| sw 1 | BGM单次关闭 | transient one-shot BGM mute |
| sw 1435 | 传送禁止 | transient "no fast-travel during event" gate |
| var 43,44 | 事件位置X/Y | scratch event coords |
| var 49,50 | 玩家X/Y | scratch player coords |
| var 51 | 怪物方向 | scratch monster facing |
| var 53 | 本图ID | scratch current-map id |
| var 81 | 敌人随机数 | scratch enemy RNG |
| var 55 | 迷幻花海计数 | per-peer wander counter (NOTE: switch 55 ≠ var 55) |
| var 76 | 花海之柱燃烧数 | pillar sequence-state, self-switch-backed |

## 5. Other confirmed-shared (earlier this session / pre-existing)

| id | name | mechanism |
|---|---|---|
| sw 20 | 时间重叠开启 | Map358 beacon time-overlap; SHARED + FX-mirror (script 1270) |
| sw 26 | 猎犬出现 | hound appears (ferry-related); SHARED (IDS) |
| self-switches | — | ALWAYS shared in the BSMP model (except shared-cutscene latches) |

---

## 6. Agent verification pass — corrections to the scout's applied batch

Three parallel sub-agents re-checked the scout's "high-confidence" additions and "NEEDS-HUMAN"
items against the condition-annotated decompile (`Trigger:` / `Condition:` now present).
The scout had already been proven wrong twice (bonfires, invasions), so nothing was trusted
on its word. Net result below; all applied to `1200 - BSMP Core.rb`.

### 6a. REMOVED from SHARED_VARIABLE_IDS (were wrong)
| var | name | why removed |
|---|---|---|
| 77 | 克莱因演出1 | live cutscene step-sequencer on Map080 (`+=` interleaved with animation); broadcasting corrupts the other peer's cutscene step → LOCAL |
| 100 | 灼热之触召唤演出 | live summon-cutscene step counter on Map221 → LOCAL |
| 286 | 贪食龙进度 | real-time Gluttony-Dragon chase/AI state (siblings 285/287 local); durable kill = switch 1110 (already shared). Owner-authority fix = task #31 |

### 6b. REMOVED from SHARED_SWITCH_IDS (were wrong)
| switch(es) | name | why removed |
|---|---|---|
| 1124 | 扭来扭去击破 | per-encounter roaming-mob respawn toggle (ON re-armed in a SelfSwitch[D] parallel page), not a one-way kill flag |
| 1138 | 坠落之屋剧情结束 | transient "cutscene playing" toggle (~40 ON / ~20 OFF across maps) |
| 1187 | 多萝西回忆剧情结束 | cutscene step state-machine (~100 toggles within Map450) |

### 6c. ADDED to SHARED_SWITCH_IDS (NEEDS-HUMAN → confirmed SHARE)
| switch | name | evidence |
|---|---|---|
| 68 | 扭曲花海意志击破 | persistent area-clear, read cross-map on Map112 |
| 82,83 | 艾因委托 开启/达成 | persistent quest-stage facts |
| 86 | 击杀古代异鱼 | persistent kill, read cross-map on Map126 |
| 89 | 异色结晶石解密成功 | persistent puzzle-solved fact |
| 338,342 | 薇拉 死亡/存活 | NPC-fate pair, many cross-map readers |
| 341 | 村庄教堂门开启 | world-geometry, cross-map (Map032/045/327/391) |
| 394,395 | V1结局达成 / 南希未得救收尾 | persistent ending/route facts |
| 1194 | 多萝西监禁事件 | NPC-fate, cross-map (Map450/451) |
| 1410 | 魔化稻草人 | persistent boss defeat-state on Map427 |
| 1412 | 杀害 (Celia killed) | NPC-death, cross-map (Map448/465) |
| 1436 | 黑色扭曲击破 | persistent "distortion cleared", cross-map |

### 6d. ADDED to SHARED_VARIABLE_IDS
| var | name | evidence |
|---|---|---|
| 1031 | 商店进度 | absolute-SET state 1-6 (NOT a counter despite name), read cross-map `>=N` — absolute broadcast correct |
| 203 | 船送点数量 | ferry dock COUNT; CE87 gates the whole ferry on `203 < 2` so the guest needs it. +=1 counter (split risk) but converges; real unlock authority = switches 90-96 |

### 6d-bis. CORRECTION — ferry docks 90-96 KEPT (a removal was reverted)
First pass (agent) wrongly tagged switches **90-96** as "transient boat-menu toggles" and they
were removed. Reading the ferry mechanic end-to-end disproves that:
- **CE88** "船送点" builds the menu: `if Switch[90] ON -> gain key-item 525 (Freud)`, … 96->531,
  97-99->532-534. So 90-99 ARE the persistent "dock unlocked" state the menu reads.
- **CE87** "Переправа" then offers the destinations whose key-items you hold, and gates the whole
  thing on `Variable[203] < 2`.
- Dock event (e.g. Map083 EV020): Page 0 (discovery) sets `90 ON` + self-switch A; Page 1 sets
  `90 OFF` for a split-second while you're at that dock's menu, then `90 ON` again in BOTH the
  Yes and No branches → net durable ON. The OFF blip is what was misread as "transient".
- Self-switch A is only the "show the boarding page" latch; it is NOT what the menu reads.
→ **90-96 restored to SHARED_SWITCH_IDS** (+ var 203 for the `<2` gate). Lesson: judge a flag by
its READER (here CE88), not just its set-sites' net ON/OFF count.

### 6e. VINDICATED (kept — earlier "remove" instinct was wrong)
- **268 / 270** (Greyhound-Squad / Sea-God sidequests): each `+=1` is gated by `ControlSelfSwitch[D]`
  → single-fire globally; self-switch syncs so the absolute broadcast converges. SAFE to share.

### 6f. Confirmed LOCAL (NEEDS-HUMAN → keep out)
1423–1427 (transform stages 1-5 — live in Troops.txt, per-battle), 1050/1051 (transient
shop-open UI lock), 1434 (live per-encounter distortion-spawn flag).

### 6g. PENDING — set-site not in Maps/CommonEvents (likely Troops.txt)
373, 1097, 1117, 1433, 1437 — boss-defeat/quest names, read-as-gate sites exist but no
`ControlSwitches` writer found in the scanned scope. Left IN the shared list (inert if never
set; if set inside a Troop battle event the host runs it → sharing is correct). **Verify set
polarity in Troops.txt before fully trusting.** Also dead-in-demo (no live wiring): 343, 358,
377, 1052 (no set+no read); 345 (set, no read); 500 (OFF-only, no ON writer).

### 6h. Counter variables — confirmed NEEDS host-tally (do NOT absolute-share)
1032 (candy), 87 (Ain commissions, mixed/random add), 265 (greed rings), 1014 (hound kills),
1028 (twisted-man kills), 1021/1025 (clue collectibles), 1034 (chests), 284 (dwarf), 1402
(Chittenango performance). Each is a per-player accumulator; absolute broadcast loses/double-
counts. 70 (Dorothy trust) & 256 (Isabella) are dead (written-never-read / never-written).
1026 is a randomized stage selector (host must decide the roll once, not per-peer). None were
in the batch — correctly excluded.

> Polarity note: many shared flags use the NG+ inverted convention — mass-initialised ON by
> CE18/Map386 (`ControlSwitches([1,200,1])` etc.), default ON = "not-done / alive / blocked",
> set OFF when resolved. The OFF transition is the persistent world fact; sharing stays correct.
