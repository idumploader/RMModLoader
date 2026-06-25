#==============================================================================
# BSMP Core — Steam P2P multiplayer framework, part 1/5: the module gate, config
# constants, packet-event dispatch and the BSMP::Packet base.
#
# BSMP is split across load-ordered files (core first, hooks last):
#   1200 Core    — module BSMP, Config, Events, Packet   (this file)
#   1210 Net     — Client / Server / ServerClient
#   1220 Players — Player_Character / Players
#   1230 UI      — windows
#   1240 Hooks   — game-class patches, $bsmp_* globals, console commands
#
# Dependencies: Steam runtime (SteamAPI, SteamCCallResult, SteamCCallback,
#               BasicNetworkPacket). Optional: ModLoader::I18n (11) for
#               translatable on-screen strings (see 1201 BSMP I18n).
# Gate: module BSMP is only defined when SteamAPI exists; every later file loads
#       its body only `if defined?(BSMP)`, so one Steam check gates them all.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP"]
$imported["IDL-BSMP"] = "1.0"

if not Object.const_defined?(:SteamAPI)
  p "Multiplayer isn't available"
else

# BasicNetworkPacket is native: its #data getter rebuilds a FRESH ASCII-8BIT Ruby string
# from the C++ byte buffer on every call, and #data= doesn't preserve a string's encoding
# tag. So tagging a packet's data UTF-8 anywhere never sticks — the next getter hands back
# ASCII-8BIT again, and a multibyte name/face later blows up (Encoding::UndefinedConversion
# at a string concat). Fix it once at the source: re-tag UTF-8 on every read. The wire is
# UTF-8, and force_encoding only changes the tag of the throwaway copy the getter returns,
# so the native bytes are untouched and Marshal-based handlers (Wire.unpack, world snapshot)
# stay byte-correct — Wire.unpack re-forces ASCII-8BIT internally before it slices framing.
class BasicNetworkPacket
  alias bsmp_raw_data data
  def data
    d = bsmp_raw_data
    d.is_a?(String) ? d.force_encoding("UTF-8") : d
  end
end

module BSMP

  class Callback

    def initialize(callback, method)
      @callback = callback
      @method = method
      @listener = nil
    end

    def on(listener)
      @listener = listener
    end

    def call(args)
      @method.call(*args)
      @listener.call
    end

  end

  module Config

    DEBUG = false

    MAJOR_VERSION = 0
    MINOR_VERSION = 2

    # Protocol compatibility (handshake). Same MAJOR is mandatory (breaking wire
    # changes bump it); a peer MINOR is accepted iff it falls in this range on BOTH
    # sides (mutual acceptance). Divergence inside the range is fine.
    ACCEPTED_MINOR_MIN = 0
    ACCEPTED_MINOR_MAX = 2

    # NB both game_title and the content hash are translation-sensitive: a translated
    # vs original copy of the SAME game differs in display strings but is structurally
    # identical (sync is by id), so it's co-op-compatible. The enforcement toggles for
    # both live in Settings (check_game / check_data_hash) so a menu can flip them; see
    # there for why the data-hash gate defaults off (BS2 patches $data_* at runtime).

    DEFAULT_SERVER_CHANNEL_ID = 0
    DEFAULT_SERVER_CLIENT_ID = 1

    # Steam ELobbyType (cast straight to ELobbyType by the native create_lobby
    # binding and handed to CreateLobby). Default visibility when hosting;
    # Settings.lobby_type defaults to LOBBY_ONLY_FRIENDS.
    LOBBY_PRIVATE      = 0   # invite-only, never listed
    LOBBY_FRIENDS_ONLY = 1   # friends/invitees see it; not in the public list
    LOBBY_PUBLIC       = 2   # friends + public lobby list
    LOBBY_INVISIBLE    = 3   # search-only, hidden from friends
    LOBBY_ONLY_FRIENDS = LOBBY_FRIENDS_ONLY   # was a stray 10 (out-of-range enum)

    LOBBY_CHAT_UPDATE_JOINED = 1

    CALL_RESULT_LOBBY_JOINED = 504
    CALL_RESULT_LOBBY_CREATED = 513

    CALLBACK_JOIN_REQUESTED = 333
    CALLBACK_LOBBY_ENTERED = 504
    CALLBACK_LOBBY_CHAT_UPDATE = 506

    SEND_FLAG_RELIABLE = 8

    # --- Shared world state (live sync) ---
    # Which switches / variables count as "shared progression" and sync live as
    # facts. self-switches are ALWAYS shared (no list). Start empty and grow as the
    # real flags are identified. Ranges are inclusive Ruby Ranges.
    SHARED_SWITCH_RANGES   = [
      # Bonfires (System/Switches.txt 101-172, ~36 of them). Odd 101-171 =
      # "<place> 篝火" (discovered/lit), even 102-172 = "<place> 篝火可用" (available to
      # fast-travel). Set by GLOBAL ControlSwitches — on the map when the bonfire is
      # reached (odd) and by CE503's story batch (even) — NOT a self-switch. The scout
      # mis-flagged this block as "derived UI / real state is a self-switch / local";
      # it is real shared world progress, so a bonfire one peer lights shows for all.
      (101..172),
      # Roaming invasions (System/Switches.txt 401-404, 441-450). Odd/appear =
      # "<boss> 出没/出现/入侵" (Albert 401, Liz 403, Crying Angel 441, Thought-projection
      # 443 +狂暴 frenzy 444, Rain-bride 445, Deep-sea-fear 447, Death-omen 449); even =
      # "<boss> 消灭/击破" (defeated record). Set by GLOBAL ControlSwitches: armed on the
      # boss's map (Map341->441, Map080->401, ...) and cleared at any bonfire by CE5/CE10;
      # the kill flag (402/442/...) is set in the on-map win branch (443/444 has no kill
      # flag — CE9 toggles it). NOT a self-switch. The appear switch gates whether the
      # invader SPAWNS at all, so an unshared roll means the invader shows for one peer
      # only (MOB_ERASE can't sync a mob that never spawned) — the scout mis-flagged this
      # as local. Sharing makes the invader spawn AND die for everyone; a bonfire rest
      # clears it world-wide (consistent shared-world reset).
      (401..404), (441..450),
    ]
    # Permanent NPC-removal world facts. BS2 gives each killable covenant NPC a named
    # switch block (System/Switches.txt 501-576): 誓约 (covenant) / 誓约解放 (covenant
    # release, transient) / 监禁 (imprisoned, "rape" route) / 杀害 (killed, "kill" route).
    # The 监禁/杀害 (and Gautier's 自杀 suicide) switches are set ON for good when the NPC is
    # removed and GATE whether the NPC still appears — verified manually: Evanora's presence
    # follows 杀害 534, NOT the covenant gate 531 (which does nothing to her presence). Sync
    # them so a killed/imprisoned NPC stays gone for every peer (live + world snapshot). The
    # 誓约/誓约解放 covenant gates are NOT here (they toggle during normal covenant play;
    # covenant rank already syncs via var 110). Switches with no kill set-site in this build
    # simply never fire, so listing the full roster is harmless and future-proof.
    SHARED_SWITCH_IDS      = [
      # --- World/story flags (non-kill) ---
      20,             # "时间重叠开启" — Map358 time-overlap beacon ON/OFF (CE55).
                      # Gates the map's "special items" event pages, so the toggle
                      # state must agree for everyone. CE55's set_tone/fog/noise are
                      # caller-only screen FX and stay local (cosmetic desync only).
      26,             # "猎犬出现" — the hound spawn. CE55 sets it ON when the beacon
                      # oscillation hits max (var48 == 10). Only the peer that toggles
                      # the device runs CE55, so although var48 (shared) reaches 10 on
                      # everyone, the "==10 -> switch 26 ON" line runs on the toggler
                      # alone; without sharing it the others keep var48=10 but never
                      # spawn the hound. Same world-spawn class as the kill flags below.
      # --- NPC kill/imprison flags ---
      502,            # Meiko: killed
      504, 521,       # Scarlett: killed, imprisoned
      509, 519,       # Nancy: killed, imprisoned
      512, 520,       # Ein: killed, imprisoned
      522, 514, 513,  # Gautier: killed, imprisoned, suicide
      517, 518,       # Klein: killed, imprisoned
      526, 525,       # Celia: killed, imprisoned
      530, 529,       # Vera: killed, imprisoned
      534, 533,       # Evanora: killed, imprisoned
      538, 537,       # Nog: killed, imprisoned
      542, 541,       # Becky: killed, imprisoned
      546, 545,       # Papel: killed, imprisoned
      550, 549,       # Doris: killed, imprisoned
      554, 553,       # Nadia: killed, imprisoned
      560, 559,       # Tamira: killed, imprisoned
      564, 563,       # Gertrude: killed, imprisoned
      568, 567,       # Duska: killed, imprisoned
      572, 571,       # Hecate: killed, imprisoned
      576, 575,       # Mary: killed, imprisoned

      # === Scout pass — world-progress flags (high-confidence). See
      # docs/bsmp-coop-sync-scout-report.md §1. Boss-defeat flags follow the same
      # init-clear / set-on-defeat pattern as the kill roster above. ===
      # -- Cross-map story gates --
      60,             # 花海守护者击破 — Flower-sea Guardian defeated
      64,             # 花海帐篷内信息获取 — tent info obtained
      73,             # 解救小女孩 — rescued the little girl
      75,             # 小女孩死亡 — little girl died
      80,             # 咒缚之渊兽击破 — Cursed-abyss Beast defeated
      88,             # 异色结晶石信息获取 — crystal-stone info obtained
      89,             # 异色结晶石解密成功 — crystal puzzle solved (cross-map read)
      68,             # 扭曲花海意志击破 — twisted-flower-sea will defeated (cross-map -> Map112)
      82, 83,         # 艾因委托 开启/达成 — Ain commission opened / done
      86,             # 击杀古代异鱼 — ancient fish killed (cross-map read -> Map126)
      # -- Flower-sea (花海) "find the girl" arc: progress 1/2/3 unlock the passage and
      # the boss pedestal. 63 is CROSS-MAP: set in Map072 but gates the Map111 boss
      # event 13 (appears on 63, despawns on the already-shared kill flag 60). --
      54,             # 花海封锁解除 — flower-sea blockade lifted (passage opens)
      61, 62, 63,     # 花海进度1/2/3 — found-the-girl progress (63 gates Map111 boss)
      72,             # 花海深处解锁 — flower-sea depths unlocked
      # -- Ferry dock unlocks: 90-96 are the PERSISTENT "dock discovered" state. CE88
      # builds the ferry menu by reading `if Switch[9N] ON -> grant that dock's travel
      # key-item` (CE87 then offers those destinations). Set ON on first discovery (dock
      # event Page 0); only flipped OFF for a split-second while standing AT that dock's
      # own menu, then restored ON in the SAME event (both Yes/No branches) -> net durable.
      # (Earlier wrongly dropped as "transient" off a misread of that OFF blip.) --
      90, 91, 92, 93, 94, 95, 96,  # 乘船点: Freud/Cathedral/Tavern/NewEmerald-E/Nancy/Joliet/Bridge-E
      # -- Bosses / story / area unlocks (mid block) --
      306,            # 索斯塞拉击破 — Sothsera defeated
      318,            # 斯科尔神父击破 — Father Skor defeated
      322, 323, 324,  # 伊瓦诺拉: apprentice / final trial / trial passed
      348,            # 湖之主击破 — Lake Lord defeated
      373,            # 汲魂树击破 — Soul-Draining Tree defeated
      378,            # 贪婪金银蛇戒指获得 — greed ring obtained (special item shown)
      379,            # 仓库篝火点绳梯开启 — warehouse rope-ladder opened
      393,            # 鱼头马击破 — Fish-Horse-Head defeated
      396,            # 娜蒂雅解密卷轴 — Nadia scroll (cross-map; sibling of var272)
      338, 342,       # 薇拉死亡 / 薇拉存活 — Vera dead / alive (NPC fate pair, cross-map)
      341,            # 村庄教堂门开启 — village church door (cross-map geometry)
      394, 395,       # V1结局达成 / 南希未得救收尾 — V1 ending / Nancy-not-saved ending
      556,            # 塔米拉合作1 — Tamira cooperation 1 (quest gate)
      # -- NG+ / unlocks / passages / doors --
      1004,           # 多周目开启 — NG+ unlocked
      1085,           # 联动职业解锁 — collab class unlocked
      1041, 1042, 1043, 1044, 1045,  # area passages (W/E/S, Qicheng-E-down, port)
      1081, 1082, 1083,              # warehouse gate / Blackhat HQ gate / pursuit
      # -- Boss-defeat / story-route flags --
      1097,           # 漆黑之兽击破 — Black Beast defeated
      1110,           # 贪食龙全灭 — Gluttony Dragon annihilated
      1116, 1117,     # 列车长 / 费提克 — Conductor / Fetik defeated
      1123,           # 小矮人死亡 — dwarf death
      1125, 1127, 1188,  # 贪婪乌鸦 / 鸦人 / 土拨鼠 defeated (1124 REMOVED: per-encounter respawn toggle, ON re-arm in parallel page)
      1130,           # 异变之源消灭 — source-of-mutation destroyed
      # 1138 坠落之屋剧情结束 REMOVED: transient "cutscene playing" toggle (~40 ON / ~20 OFF)
      1149,           # 骸之狩猎者击破 — Bone Hunter defeated
      1150, 1151,     # 狂化屠夫1/2击破 — Berserk Butchers defeated
      1152,           # 地道钥匙出现 — tunnel key appears
      1157,           # 教堂门魔物击破 — church-door monster defeated
      1164,           # 希莉娅魔兽化击破 — Celia beast-form defeated
      1165, 1166,     # 格劳杀害 / 魔兽化击破 — Grau killed / beast-form defeated
      1167,           # 希莉娅救赎失败 — Celia redemption FAILED
      1168,           # 格劳对话完毕 — Grau dialogue done
      1175,           # 芒奇金首领击破 — Munchkin King defeated
      1176,           # 湖港镇船修复 — lake-port boat repaired
      # 1187 多萝西回忆剧情结束 REMOVED: cutscene step state-machine (~100 toggles in Map450)
      1189, 1190,     # 胆小兔击破 / 门开启 — Timid Rabbit defeated / door open
      1192,           # moko商人杀害 — Moko merchant killed
      1194,           # 多萝西监禁事件 — Dorothy imprisonment (cross-map NPC fate)
      1218, 1219,     # 地下新入口开启 / 警笛头击破 — underground entrance / Siren Head
      1236,           # 受诅咒蛙击破 — Cursed Frog defeated
      1409, 1411,     # 稻草人击破 / 奇特南戈城演出结束 — Scarecrow / Kitenango cutscene
      1410,           # 魔化稻草人 — demonized scarecrow defeat-state (must agree)
      1412,           # 杀害 — Celia killed (cross-map NPC death)
      1436,           # 黑色扭曲击破 — black-distortion defeated (cross-map)
      1413, 1415, 1416, 1430,  # 希莉娅支线: open / complete / redemption success / line open
      1417, 1418, 1419, 1420,  # 圣堂支线: scene1 / scene2 / all-cleared / scene3
      1431, 1432,     # 真父亲离开 / 父亲死亡 — true father leaves / father death
      1433,           # 坠落之屋任务开启 — Fallen-House quest opened
      1437,           # 黑渊之骸击破 — Black-Abyss Husk defeated
      # -- Bonfires --
      1438, 1442, 1443, 1444,  # 黑渊 / 坠落之屋 / 废镇西 / 地下入口 篝火 (bonfires)
    ]
    SHARED_VARIABLE_RANGES = []
    # Covenant rank (world progress): leveling at the covenant NPC (CE909) does
    # var += 1 after paying souls. Sharing the rank var syncs the rank to everyone
    # while only the initiator pays / keeps the personal token. var 110 = Evanora's
    # covenant (Map242). Add other covenant NPCs' rank vars here as identified.
    SHARED_VARIABLE_IDS    = [
      102,    # Covenant lvl: Umeko
      104,    # Covenant lvl: Scarlett
      107,    # Covenant lvl: Klein [Dorothea]
      105,    # Covenant lvl: Nancy
      106,    # Covenant lvl: Ain
      108,    # Covenant lvl: Celia [Tamira, Mary, ...]
      109,    # Covenant lvl: Vera
      110,    # Covenant lvl: Evanora
      112,    # Covenant lvl: Betcy
      111,    # Covenant lvl: Nog
      114,    # Covenant lvl: Isabella
      115,    # Covenant lvl: Gertruda

      # --- Story / world-progress counters (absolute or monotonic) ---
      48,     # "星炬波动计数" — time-overlap beacon oscillation counter; CE55 does
              #  v48 += 1 on each activation. Broadcast carries the absolute value,
              #  so peers converge without double-counting the increment.
      272,    # "娜蒂雅演出1" — Map358: set to 1 on the fish-boss win (IfWin), then 2
              #  after the rope-ladder scene; gates the rope. Absolute set.

      # === Scout pass — idempotent absolute story/scene/sidequest stage markers (same
      # shape as var272). See docs/bsmp-coop-sync-scout-report.md §3. ===
      36,     # ☆主线流程 — main-story progress (central counter, gates NPC dialogue)
      59,     # ☆世界探索进度 — world-exploration progress
      78, 79, 80,       # 克莱因演出 2-4 — Klein scenes (pure abs sets). 77 REMOVED:
                        #  live cutscene step-sequencer (+= interleaved with animation) -> LOCAL
      82, 84, 85, 86,   # 南希演出 1 / 2 / 3 / 2.5 — Nancy scenes
      88, 89,           # 艾因演出 1 / 2 — Ain scenes
      91,     # 绯红暴君状态 — Crimson Tyrant state
      92,     # 楼演出进度1 — tower scene progress 1
      93,     # 萨卡班甲鱼演出 — Sacaban-fish scene
      99,     # 圣心教堂boss演出1 — Sacred-Heart boss scene 1
      # 100 灼热之触召唤演出 REMOVED: live summon-cutscene step counter (Map221) -> LOCAL
      210,    # 索斯赛拉finale — Sothothera finale
      215,    # 魔女之家演出1 — Witch's House scene 1
      217, 218, 219, 220,  # 薇拉演出 2.5 / 1 / 2 / 3 — Vera scenes
      250,    # 试玩通关 — demo cleared
      266,    # 神秘学者支线 — occultist sidequest
      268,    # 灰猎犬小队支线 — Greyhound-Squad sidequest (VERIFIED: each += gated by
              #  SelfSwitch[D] -> single-fire global, abs converges; safe)
      270,    # 海神封印支线 — Sea-God Seal sidequest (VERIFIED: += behind SelfSwitch[D] one-shot)
      271,    # 鱼头马演出 — Fish-head Horse scene
      273,    # 卧底支线 — undercover sidequest
      274,    # 花庭传送解锁 — Flower-Court teleport unlock
      276,    # 教堂神职人员剧情 — cathedral cleric story
      277,    # 塔米拉开启海德拉 — Tamira opens Hydra
      281, 282,         # 葛特露演出 1 / 2 — Gertruda scenes
      # 286 贪食龙进度 REMOVED: real-time chase/AI state (siblings 285/287 local); the
      #  durable kill is switch 1110 (already shared). Owner-authority fix -> task #31
      289,    # 贪婪与毁灭支线 — Greed & Destruction sidequest
      290,    # 最后幸存者支线 — Last Survivor sidequest
      297,    # 伊瓦诺拉刺杀血迹 — Evanora assassination bloodstain
      298,    # 礼拜堂沉睡演出 — chapel sleeping scene
      299,    # 伊瓦诺拉浇花 — Evanora watering flowers
      1401,   # 八音盒支线进度 — Music-Box sidequest progress
      1404,   # 圣域支线进度 — Sanctuary sidequest progress
      1031,   # 商店进度 — shop progress (VERIFIED: absolute-SET state 1-6, cross-map read; not a counter despite the name)
      203,    # 船送点数量 — ferry dock COUNT. CE87 gates the whole ferry on `203 < 2`
              #  ("no new dock"), so the guest must have it or they're locked out even
              #  with docks 90-96 shared. It's a +=1 counter (split risk) but converges in
              #  practice; the real unlock authority is switches 90-96, this is just the gate.
    ]

    # --- Co-op "local" common events (step 6.5) ---
    # Common events whose item/gold gains must NOT be instanced to other peers via
    # the Loot broadcast (1246) — they're personal Souls-style operations (Estus
    # refill on rest/death). Both sets run "local" (ChangeItems stays on the running
    # peer); the difference is who runs them:
    #   PERSONAL = only the acting peer runs it (CE 2 = bonfire rest).
    #   SHARED   = additionally mirrored so EVERY peer runs its own (CE 12 = death).
    # The mirror itself is wired separately; this list only governs loot locality.
    PERSONAL_COMMON_EVENT_IDS = [
      2,                  # Bonfire rest (Estus refill)
      # Map108 "Veronika" merchant — soul/material -> gear crafting. Each player
      # spends their OWN souls/materials and must keep their OWN result; the gear
      # grant (ChangeWeapons/Armor/Items, command 126-128) would otherwise instance
      # to every peer via the loot broadcast. Her "buy" options (CE 84/85) use
      # ShopProcessing instead, which is already personal, so they're not listed.
      510, 511, 512,      # Smelt special soul -> weapon / armor / accessory
      540,                # Recycle space-time shards -> items
      87,                 # Ferry ("Переправа"). Builds a throwaway key-item menu: CE88
                          # (called from here) grants one transient destination ticket
                          # (items 525-534) per unlocked dock so SelectKeyItem can list
                          # them, then this CE removes 525-531 again at the end. Those
                          # +1 grants would loot-broadcast and pile up on the OTHER peers
                          # (who never run the matching cleanup), making the normally
                          # invisible service items appear in their bags. Local CE88
                          # inherits the flag (1246 command_117), so both ends stay
                          # per-peer. Pure transient bookkeeping -> never a shared grant.
    ]
    SHARED_COMMON_EVENT_IDS   = [
      12,  # Death
    ]

    # --- Co-op shared story cutscenes (watched by EVERY peer, not only the owner) ---
    # By default a guest does NOT run an autorun/parallel page gated on a synced flag:
    # the map owner runs it once and the result flags sync (see 1245). That is right
    # for world-progression logic (spawns, counters, battles) but wrong for a STORY
    # cutscene everyone present should watch. Listing an event here (a) lets guests run
    # its autorun too and (b) keeps that event's self-switch latch LOCAL (per-peer), so
    # the first viewer finishing doesn't flip the others' page past the scene before
    # they see it. ONLY for IDEMPOTENT scenes — dialogue, local transfer, absolute flag
    # sets — never loot / battle / relative counters (those would double up).
    # { map_id => [event_id, ...] }
    SHARED_CUTSCENE_EVENTS = {
      358 => [22],   # post-fish "rope ladder" dialogue (Nadia): autorun on var272>=1,
                     #  sets var272=2 + self-switch A. Pure idempotent story beat.
    }

    # --- Per-map-event switch-broadcast filter (ControlSwitches command_121) ---
    # Some MAP events toggle a SHARED switch in a way that is partly world progress and
    # partly per-player. The ferry docks are the case: switch 90-96 ON = "dock discovered"
    # (world, must sync), but the dock event also flips it OFF for a split-second while you
    # stand AT that dock (so its own menu, CE88, omits "travel to where I am") then ON again.
    # That transient OFF is per-player and must NOT leak. We can't bracket the map event
    # (its OFF is the page's first command), so we filter at command_121 by (map, event).
    #   :on_only -> broadcast the ON write (carries the discovery), keep OFF local. The ON
    #     also delivers discovery to a peer who never ran the event's Page 0 (its self-switch
    #     synced and flipped them to the menu page). NG+ clears docks via CE18's mass reset,
    #     NOT these events, so the reset OFF still propagates.
    #   :local   -> keep BOTH directions local (a fully per-player switch write). For future.
    # The local set still happens; only the network broadcast is filtered.
    # { map_id => [[event_id, mode], ...] }
    PERSONAL_MAP_EVENTS = {
      80  => [[197, :on_only]],  # ferry dock: New-Emerald East (switch 93)
      82  => [[153, :on_only]],  # ferry dock: Cathedral (switch 91)
      83  => [[20,  :on_only]],  # ferry dock: Freud commercial (switch 90)
      85  => [[55,  :on_only]],  # ferry dock: Tavern (switch 92)
      92  => [[103, :on_only]],  # ferry dock: Emerald-bridge East (switch 96)
      137 => [[22,  :on_only]],  # ferry dock: Joliet port (switch 95)
      210 => [[2,   :on_only]],  # ferry dock: Nancy hideout (switch 94)
    }

    # --- Co-op battle scaling (step 6.6) ---
    # Enemies scale with the number of PLAYERS in the fight (1 = no scaling). co-op
    # battles are global, so "players" = lobby size; the value is stable for the whole
    # fight and identical on every peer (synced roster), so enemy stats agree.
    # factor = 1 + (players - 1) * rate. The ATB action economy is the main axis — a
    # bigger party simply gets more turns — so enemy SPEED (ATB charge rate) is the
    # primary lever; HP is a secondary "longer fight" knob. Set a rate to 0 to disable
    # that lever. Tune freely in playtest; both are pure multipliers.
    BATTLE_SCALE_SPEED_PER_PLAYER = 0.5  # +50% enemy ATB charge per extra player
    BATTLE_SCALE_HP_PER_PLAYER    = 0.25 # +25% enemy max HP per extra player

    # --- Co-op consensus gates (step 6.7) ---
    # Map events everyone must reach & confirm before they fire (boss fog, NG+ stone),
    # auto-wrapped WITHOUT editing the map. { map_id => [entry, ...] } where an entry is
    # a bare event_id, OR an ARRAY of event_ids that share ONE gate (e.g. several tiles
    # of the same fog wall — confirming any tile counts for all). Only PLAYER-TRIGGERED
    # pages gate (action / touch); autorun & parallel pages are never gated. When all
    # players have confirmed, every peer resumes the event body; a battle inside is run
    # by the host (others join via BATTLE_START). NOTE the gate fires at the START of the
    # event (on interact). For a fog with a "pass? yes/no" prompt where the gate should
    # come AFTER "yes", hand-place `bsmp_ready_gate("id")` in that branch instead.
    READY_GATE_EVENTS = {
      # 123 => [4, 7],      # map 123: events 4 and 7 are separate gates
      # 181 => [[4, 5, 6]], # map 181: events 4,5,6 are ONE fog wall -> one shared gate
      10  => [11],           # Boss fog
      44  => [35],           # Boss: Celia
      54  => [[32, 33, 34]], # Boss fog: Scarecrow
      88  => [55],           # Boss: Bok
      93  => [
        [43, 75, 76, 77, 78] # Boss fog wall: 
      ], 
      111 => [13],           # Boss: Flower
      153 => [15],           # Boss: Klein
      181 => [[4, 5, 6]],    # Scarlet fog wall (3 tiles, shared gate)
      211 => [
        63,                  # Boss fog: Erick
        43,                  # Boss fog: Socera
      ],       
      214 => [49],           # Boss: Fish
      220 => [31],           # Boss: Horse
      221 => [25],           # Boss: Firedick
      238 => [12],           # Boss: Skeleton
      243 => [3],            # Train: Evanora
      326 => [12],           # Boss: Grey
      323 => [12],           # Encounter: Grey
      344 => [31],           # Boss: Hydra
      393 => [89],           # Boss: Grey (2 phase)
      395 => [9],            # Boss: Manchkin king
      404 => [12],           # Boss: Frog
    }

    # --- Consensus gate on irreversible dialogue choices ---
    # A Show Choices whose chosen option (after stripping \c[n] colour codes, matched
    # case-insensitively and EXACTLY — not as a substring) equals one of these words is
    # treated as a point of no return (an NPC kill). The acting player parks at a ready
    # gate until EVERY player has reached the SAME choice and confirmed it; a holdout
    # never arrives -> no kill, and the actor can press cancel (B) to back out. Exact
    # match keeps "Не убивать" / "Убить монстра" from tripping it; add wordings here as
    # found. Trailing punctuation (?, !, .) is ignored, so "Изнасиловать?" matches too.
    # Empty disables the feature. Kill (杀害) and rape/imprison (监禁) are both permanent.
    CHOICE_GATE_WORDS = ["убить", "убийство", "изнасиловать", "杀害", "杀", "kill"]

    # --- Host-driven mobs (step 4) ---
    # The host re-broadcasts the positions of all moving events on its current map
    # every this many frames; guests on that map glide their copies to match. Small
    # = smoother but chattier (zlib + "only movers" keep it cheap).
    MOB_SYNC_INTERVAL = 4
    # Tiles of position error before a guest hard-snaps a mob instead of gliding
    # (teleport, map seam, first sync). Mirrors the remote-player SNAP_DISTANCE.
    MOB_SNAP_DISTANCE = 3

    # --- co-op battle (step 6) ---
    # The host re-broadcasts its troop's battler state (HP/MP/ATB) every this many
    # frames so a guest's mute battle scene mirrors it. Enemy HP barely changes
    # between hits, so this is mostly about how smoothly the ATB gauges step.
    BATTLE_SYNC_INTERVAL = 4

    # Combined party (step 6.3b). Every this many frames each player re-broadcasts its
    # OWN battle actors (BATTLE_ACTOR) so every peer can build/refresh a render proxy of
    # everyone else — periodic so a player who joins mid-battle catches up within this
    # window. Lower frequency than BATTLE_SYNC: identity/params barely change, the live
    # HP/MP/ATB rides BATTLE_PARTY_SYNC instead.
    BATTLE_ROSTER_INTERVAL = 30

    # Auto-rejoin (shared-battle guarantee). The co-op battle is global — nobody should
    # be running around the map while a fight is live. So the host re-announces its live
    # battle (re-broadcasts BATTLE_START) every this many frames. Any peer that's on the
    # map and NOT already in the battle (a fresh joiner, a guest that F12-reset and
    # reloaded its save, or one the watchdog bailed) picks it up and gets pulled back in.
    # A peer already a mute client ignores it (on_battle_start early-returns). Slow: this
    # is a recovery net, not a hot path — ~1s is fine.
    BATTLE_REANNOUNCE_INTERVAL = 60

    # Heartbeat watchdog: a mute guest that hasn't received ANY battle state from the
    # host for this many of its own frames assumes the host's battle is over / lost and
    # bails to the map. Catches a BATTLE_END missed during an F12 reset (the guest
    # re-enters a battle the host already left) or any desync. The host streams during
    # waits too (update_for_wait), so normal emerge / charge / animation pauses never
    # starve the guest — only the host genuinely leaving its battle does. Generous so a
    # brief host window-defocus (RGSS pauses unfocused) doesn't wrongly kick the guest.
    BATTLE_STARVE_FRAMES = 300

    # Remote-turn input (6.4): frames the host waits for a guest's command before
    # auto-resolving its turn (a plain attack), so an AFK/silent guest never hangs the
    # fight. A true disconnect is caught at once (no owner), independent of this. Doubles
    # as the guest's on-screen turn-timer length. ~2 min @ 60fps; overridable in settings.
    BATTLE_INPUT_TIMEOUT = 7200

  end

  # Runtime, user-changeable preferences — as opposed to Config, which is fixed
  # protocol / wire / Steam-enum values. A future in-game settings menu flips these
  # live (host lobby visibility, the strict content-hash gate, the roster key, ...);
  # they default to the previous constants so behaviour is unchanged. Access the
  # singleton via BSMP.settings.
  #
  # Backed by ModLoaderNVRAM when that build is present: edits live in an in-memory
  # working copy and #commit flushes the whole section to mod_loader/nvram.dat, so
  # preferences survive restarts. On a build without the store we keep the same
  # working-copy interface in memory only (settings just reset each launch). Either
  # way the live values (handshake gate, lobby type, ...) read the working copy, so
  # a console tweak takes effect immediately; #commit only governs persistence.
  class Settings
    DEFAULTS = {
      :check_game      => true,                       # reject a peer whose game (title) differs
      :check_data_hash => false,                      # strict gameplay-database fingerprint gate
      :lobby_type      => Config::LOBBY_ONLY_FRIENDS, # Steam ELobbyType used when hosting
      :max_players     => 10,                         # lobby capacity when hosting
      :roster_key      => ModLoader::Keyboard::TAB,   # key (ModLoader VK) for the roster overlay
      :roster_mode     => :hold,                       # :hold (show while held) or :toggle (press to flip)
      :debug           => false,                      # runtime diagnostic logging (BSMP.log / debug_log)
      :debug_packets   => false,                      # per-packet wire trace firehose (independent of :debug)
      :log_to_file     => false,                      # also write the log to mod_loader/bsmp-log.txt (survives a long session)
      :log_mark_key    => ModLoader::Keyboard::F7,    # hotkey: drop a context-stamped marker into the log ("bug here")
      # Co-op battle heartbeat watchdog: frames (~60/s) a mute guest waits without ANY
      # host battle state before assuming the host left its battle (missed BATTLE_END,
      # e.g. across an F12 reset) and bailing to the map. 0 disables it. Generous by
      # default so a host window-defocus (RGSS pauses unfocused, unless ModLoader keeps
      # the thread running) doesn't wrongly kick the guest.
      :battle_watchdog_frames => Config::BATTLE_STARVE_FRAMES,
      # How long (frames) the host waits for a guest's battle command before auto-acting
      # for it; also the length of the guest's on-screen turn timer (6.4).
      :battle_input_timeout_frames => Config::BATTLE_INPUT_TIMEOUT,
      # The top-corner "BSMP HOST/CLIENT - N online" status plate. Toggle it off, or slide
      # it anywhere with the relative position (% across the free width / down the free
      # height; 100/0 = the default top-right). Lets the player move it off a spot where it
      # would cover on-screen text / descriptions.
      :show_status_plate => true,
      :status_plate_x    => 100,  # 0 = flush left, 100 = flush right
      :status_plate_y    => 0,    # 0 = top,        100 = bottom
      # World snapshot (join / resync) scope. Default applies ONLY the shared world
      # (SHARED_* switches/variables, plus self-switches + spirits which are inherently
      # world state) — a joiner adopts the host's world PROGRESS without its peer-LOCAL
      # switches/vars getting overwritten (consistent with the live sync, which already
      # filters by SHARED_*). Flip ON for the legacy WHOLESALE copy (every switch + every
      # non-zero var) as an emergency hard re-sync if something desyncs badly. Host-side:
      # the host's setting is stamped into the snapshot, so the receiver applies the right
      # mode regardless of its own setting.
      :world_snapshot_full => false,
    }

    # Typed accessors over the backing store; setters edit the working copy only
    # (call #commit to persist — a settings menu does this on "Apply").
    DEFAULTS.each_key do |field|
      define_method(field)        { @data[field] }
      define_method("#{field}=")  { |value| @data[field] = value }
    end

    def initialize
      @data = open_backing
      sanitize
    end

    # Repair values an older build may have persisted out of range, so a stale
    # NVRAM section can't carry a bad value forward. Currently: the stray
    # lobby_type 10 that predated the ELobbyType fix (valid range 0..3). Edits the
    # working copy only; the next #commit (e.g. a menu change) flushes the repair.
    def sanitize
      lt = @data[:lobby_type]
      unless lt.is_a?(Integer) and lt >= Config::LOBBY_PRIVATE and lt <= Config::LOBBY_INVISIBLE
        @data[:lobby_type] = DEFAULTS[:lobby_type]
      end
    end

    # NVRAM section (persisted, defaults fill missing keys) when the store exists,
    # else a same-interface in-memory stand-in so a build without it still runs.
    def open_backing
      if defined?(ModLoader) and ModLoader.respond_to?(:nvram)
        ModLoader.nvram.section(:bsmp, DEFAULTS)
      else
        VolatileSection.new(DEFAULTS)
      end
    end

    # Persist current values (settings-menu "Apply" / after a console tweak). No-op
    # when nothing changed.
    def commit
      @data.commit
      self
    end

    # Drop unsaved edits, restoring the last persisted values (menu "Cancel").
    def reload
      @data.reload
      self
    end

    # Restore defaults in the working copy (commit to persist).
    def reset
      DEFAULTS.each { |k, v| @data[k] = v }
      self
    end

    def to_h
      @data.to_h
    end

    # Apply a subset of keys (e.g. from a menu); unknown keys ignored so an older
    # stored section can't crash a newer build.
    def update(hash)
      hash.each { |k, v| @data[k] = v if DEFAULTS.key?(k) }
      self
    end

    # Minimal in-memory stand-in for ModLoaderNVRAM's Section, used on builds that
    # don't ship the store — same surface we rely on, persistence is a no-op.
    class VolatileSection
      def initialize(defaults); @h = defaults.dup; end
      def [](key);        @h[key];        end
      def []=(key, value); @h[key] = value; end
      def to_h;  @h.dup; end
      def commit; self;  end
      def reload; self;  end
    end
  end

  def self.settings
    @settings ||= Settings.new
  end

  # Roster visibility for :toggle mode — kept at module level (not on the
  # per-map spriteset) so a press-to-show survives map transfers. Hold mode
  # ignores it; reset when networking stops (dispose_bsmp_windows).
  def self.roster_shown?;        @roster_shown ||= false; end
  def self.roster_shown=(value); @roster_shown = value;   end

  # Runtime diagnostic log, off by default. Flip BSMP.settings.debug = true (e.g. on
  # both machines) to trace behaviour over the wire and read the console; flip
  # :log_to_file to also persist it to mod_loader/bsmp-log.txt (survives a long
  # session, where the console scrollback wouldn't). Either flag emits.
  def self.log(msg)
    return unless settings.debug or settings.log_to_file
    p "[BSMP] #{msg}" if settings.debug
    file_log(msg)
  end

  # Lazy variant: the block is evaluated ONLY when something wants it, so a (frequently
  # interpolated, sometimes bursty) message string is never built in the hot path when
  # logging is off. Prefer over `log("...#{x}...") if settings.debug` — that form
  # still builds the string every call because Ruby evaluates args first.
  def self.debug_log
    return unless settings.debug or settings.log_to_file
    s = yield
    p "[BSMP] #{s}" if settings.debug
    file_log(s)
  end

  # Per-packet wire firehose, behind its own flag so plain :debug stays readable.
  # Fires on every packet (movement spam included) — keep block-form and opt-in. Goes
  # to the file too (only) when both its flag and :log_to_file are on.
  def self.debug_packet_log
    return unless settings.debug_packets
    s = yield
    p "[BSMP] #{s}"
    file_log(s)
  end

  # --- file log sink (opt-in via :log_to_file) ------------------------------
  LOG_MAX_BYTES = 8_000_000   # rotate at ~8 MB (keep one .old) so a long session
                              # can't balloon — worst case ~16 MB on disk, never GBs.

  def self.log_file_path
    @log_file_path ||= File.join(ModLoader.data_directory, "bsmp-log.txt")
  end

  # Short per-line stamp: wall-clock (to correlate the two players' logs) + the RGSS
  # frame counter (per-machine ordering). Never raises.
  def self.log_stamp
    "#{Time.now.strftime('%H:%M:%S')} f#{Graphics.frame_count}"
  rescue StandardError
    ""
  end

  # Append a line to the log file, rotating at LOG_MAX_BYTES. No-op unless
  # :log_to_file. Wrapped so logging can never crash gameplay.
  def self.file_log(msg)
    return unless settings.log_to_file
    path = log_file_path
    @log_bytes ||= (File.exist?(path) ? File.size(path) : 0)
    if @log_bytes > LOG_MAX_BYTES
      old = path.sub(/\.txt\z/, ".old.txt")
      File.delete(old) if File.exist?(old)
      File.rename(path, old) if File.exist?(path)
      @log_bytes = 0
    end
    line = "[#{log_stamp}] #{msg}\n"
    File.open(path, "a") { |f| f.write(line) }
    @log_bytes += line.bytesize
  rescue StandardError
  end

  # Drop a context-stamped marker into the log — the "I just saw a bug" button
  # (default F9, BSMP.settings.log_mark_key). The auto-captured context (map, our
  # tile, role, players online, owner-here, in-battle) is what makes a bare marker
  # actually useful after the fact. Always prints; persists when :log_to_file is on.
  def self.mark_log(note = nil)
    @mark_seq = (@mark_seq || 0) + 1
    bits = ["MARK ##{@mark_seq}"]
    bits << note.to_s if note and not note.to_s.empty?
    bits << "map=#{$game_map.map_id}(#{current_location_name})" if $game_map
    bits << "pos=#{$game_player.x},#{$game_player.y}" if $game_player
    bits << "role=#{host? ? 'host' : (guest? ? 'guest' : 'solo')}"
    bits << "online=#{($bsmp_players ? $bsmp_players.size : 0) + 1}"
    bits << "owner_here=#{BSMP::World.map_owner_here?}" if defined?(BSMP::World)
    bits << "in_battle=#{$game_party ? $game_party.in_battle : '?'}"
    line = "=== #{bits.join(' ')} ==="
    p "[BSMP] #{line}"
    file_log(line)
  rescue StandardError => e
    p "[BSMP] mark_log failed: #{e}"
  end

  # A common event whose body runs "local-only": its item/gold gains must not be
  # instanced to other peers (Souls Estus refill on bonfire rest / death). True for
  # both the personal and shared/mirrored sets. See [[bsmp Loot]] (1246).
  def self.local_ce?(id)
    Config::PERSONAL_COMMON_EVENT_IDS.include?(id) or
      Config::SHARED_COMMON_EVENT_IDS.include?(id)
  end

  # A common event mirrored to every peer on a co-op battle loss (death). A subset of
  # local_ce? — mirrored CEs also run loot-local on each peer. Drives MIRROR_CE.
  def self.shared_ce?(id)
    Config::SHARED_COMMON_EVENT_IDS.include?(id)
  end

  # Switch-broadcast filter mode for a running MAP event's ControlSwitches (command_121),
  # or nil if unfiltered. See Config::PERSONAL_MAP_EVENTS. event_id 0 (a common event /
  # no map event) is never matched, so CE-driven writes (e.g. NG+ CE18) are unaffected.
  def self.personal_map_event_mode(map_id, event_id)
    return nil if event_id.nil? or event_id == 0
    list = Config::PERSONAL_MAP_EVENTS[map_id]
    return nil unless list
    pair = list.assoc(event_id)
    pair && pair[1]
  end

  # Number of players in a co-op battle (6.6). co-op battles are global, so this is the
  # lobby size; 1 when solo/offline (no scaling). Stable for the whole fight and equal
  # on every peer (synced roster), so enemy scaling agrees across host and guests.
  def self.battle_player_count
    return 1 unless bsmp_network_running?
    return 1 if $bsmp_players.nil?
    1 + $bsmp_players.size
  end

  # Enemy stat multiplier: +`rate` per EXTRA player. 1.0 when solo or rate <= 0.
  def self.battle_scale(rate)
    n = battle_player_count
    return 1.0 if n <= 1 or rate <= 0
    1.0 + (n - 1) * rate
  end

  # Wire framing for BasicNetworkPacket.data: a 1-byte flags header followed by the
  # payload, optionally zlib-compressed. Lives entirely in Ruby — the native packet
  # treats data as an opaque binary blob — so the C++ transport stays untouched and
  # there's room for more flag bits later. Applied ONLY at the true wire boundary
  # (Client/Server send + read); packets dispatched locally stay plaintext.
  module Wire

    FLAG_COMPRESSED = 0x01

    # Below this many bytes deflate rarely wins and just burns CPU, so movement spam
    # and other tiny packets ship raw (paying only the 1-byte flag).
    COMPRESS_THRESHOLD = 256

    # data (any encoding) -> framed binary string: flags byte + payload.
    def self.pack(data)
      bin = data.to_s.dup.force_encoding("ASCII-8BIT")
      if bin.bytesize >= COMPRESS_THRESHOLD
        deflated = Zlib::Deflate.deflate(bin, Zlib::BEST_COMPRESSION)
        # Only flag compressed if it actually shrank (deflate can grow tiny/noisy data).
        return flag_byte(FLAG_COMPRESSED) + deflated if deflated.bytesize < bin.bytesize
      end
      flag_byte(0) + bin
    end

    # framed binary string -> original payload (binary). Tolerates empty input.
    def self.unpack(data)
      return "" if data.nil? or data.bytesize == 0
      # Treat the frame as raw bytes: the packet getter now hands us a UTF-8-tagged string,
      # and [] would then slice by CHARACTERS — wrong for binary framing. Force ASCII-8BIT
      # first so getbyte/[] index by bytes.
      data = data.dup.force_encoding("ASCII-8BIT")
      flags = data.getbyte(0)
      body = data[1, data.bytesize - 1] || ""
      (flags & FLAG_COMPRESSED) != 0 ? Zlib::Inflate.inflate(body) : body
    end

    # Build a framed COPY of packet and hand it to the native sender, leaving the
    # caller's packet untouched (some are dispatched locally right after sending).
    def self.send_framed(user_id, channel_id, packet, flags)
      framed = BasicNetworkPacket.new(packet.type, packet.from_id, pack(packet.data))
      SteamAPI.send_basic_packet(user_id, channel_id, framed, flags)
    end

    def self.flag_byte(bits)
      [bits].pack("C")
    end

  end

  # map / location naming helpers (BSMP.current_location_name / current_map_payload /
  # location_name) live in 1205 - BSMP World.rb, next to the rest of the map logic.

  # shared world-state classification (shared_switch? / shared_variable? /
  # world_owned_condition?) lives in BSMP::World — it sits next to the snapshot
  # dump/load that walks the same Config shared-id sets.

  # --- network role ---------------------------------------------------------

  def self.host?
    $bsmp_server and $bsmp_server.running?
  end

  def self.guest?
    $bsmp_client and $bsmp_client.connected? and not host?
  end

  module Events

    def self.on_packet(packet)
      # packet.data is UTF-8 for free now — BasicNetworkPacket#data re-tags on every read
      # (see the reopen at the top of this file), so handlers never need force_encoding.
      handler = HANDLERS[packet.type]
      handler.call(packet) if handler
    end

    def self.on_player_joined(packet)
      BSMP.debug_log { "Player #{packet.from_id} joined" }
      $bsmp_players.add(packet.from_id, packet.data)
    end

    def self.on_player_leaved(packet)
      BSMP.debug_log { "Player #{packet.from_id} leaved" }
      $bsmp_players.delete(packet.from_id)
      # The host's registrar drops the leaver's map ownership (releasing the map for
      # reassignment). World owns this logic; Net just hands us the leaver id.
      BSMP::World.handle_player_leaved(packet.from_id)
    end

    # True when we're on a real map and this peer is on a DIFFERENT real map, so its
    # movement must NOT be simulated against our geometry: network_move/network_moveto
    # run on $game_map (passability, width-wrap), so applying an off-map peer's steps
    # here corrupts its stored position — it reappears "standing in the wrong spot"
    # when we follow it over. With either side still map-less (title/load, map_id 0)
    # we apply, so a joiner's initial position isn't dropped.
    def self.peer_elsewhere?(from_id)
      pl = $bsmp_players[from_id]
      return false if pl.nil? or $game_map.nil? or $game_map.map_id == 0 or pl.map_id == 0
      pl.map_id != $game_map.map_id
    end

    def self.on_player_moved(packet)
      return if not SceneManager.scene_is?(Scene_Map) # needs a loaded map (round_x_with_direction)
      return if peer_elsewhere?(packet.from_id)
      dir = packet.data.to_i
      $bsmp_players.move_player_straight(packet.from_id, dir)
    end

    def self.on_player_changed_pos(packet)
      # No scene guard: positioning is plain data (network_moveto handles the no-map
      # case), so a joiner's initial position isn't dropped off-map. But skip a peer
      # on a DIFFERENT map — moveto would wrap its coords to our width and misplace it.
      return if peer_elsewhere?(packet.from_id)
      pos = packet.data.split(';')
      $bsmp_players.player_moveto(packet.from_id, pos[0].to_i, pos[1].to_i)
    end

    def self.on_player_changed_speed(packet)
      speed = packet.data.to_i

      # p "Player #{packet.from_id} changed move speed to #{speed}"
      $bsmp_players.set_player_speed(packet.from_id, speed)
    end

    def self.on_player_changed_character(packet)
      # No scene guard: this is plain data (graphic/nick); the sprite picks it up
      # when it exists. Dropping it off-map loses a joiner's graphic until it changes.
      character_name, character_index, nickname = packet.data.force_encoding("UTF-8").split(';')

      # Debug-only: this can arrive in bursts (e.g. a flurry of Game_Player#refresh on a
      # battle/map transition), and console writes are slow enough to visibly stutter.
      BSMP.debug_log { "Player #{packet.from_id} changed sprite to #{character_name}/#{character_index}, nick to #{nickname}" }
      $bsmp_players.set_player_character(packet.from_id, character_name, character_index.to_i, nickname)
    end

    def self.on_player_changed_map(packet)
      # No scene guard: set map_id ALWAYS (it's the visibility key). A joiner from the
      # title received its peers' CHANGED_MAP before being on a map, the guard dropped
      # it, and the peer stayed invisible (map_id 0) until they next changed maps. The
      # sprite add is handled by the spriteset reconcile once we're on the map; the
      # sprite update inside set_player_map is itself scene-guarded.
      map_s, loc = packet.data.force_encoding("UTF-8").split(';', 2)
      map = map_s.to_i

      BSMP.debug_log { "Player #{packet.from_id} moved to map #{map} (#{loc})" }
      $bsmp_players.set_player_map(packet.from_id, map)
      $bsmp_players.set_player_location(packet.from_id, loc.to_s)
      # A peer just arrived on OUR map — re-announce our position so it places us at
      # once, even while we stand still (else we're invisible / offset to it until our
      # next move sends a fresh anchor).
      $game_player.send_pos_packet if $game_player and $game_map and map == $game_map.map_id
    end

    def self.on_player_moved_diag(packet)
      return if not SceneManager.scene_is?(Scene_Map)
      return if peer_elsewhere?(packet.from_id)
      horz, vert = packet.data.split(';')

      $bsmp_players.move_player_diagonal(packet.from_id, horz.to_i, vert.to_i)
    end

    def self.on_save_contents_part(packet)

    end

    def self.on_player_ping(packet)
      $bsmp_players.set_player_ping(packet.from_id, packet.data.to_i)
    end

    # Grant our own copy of loot another player picked up (instanced loot). Runs the
    # real interpreter command on a throwaway interpreter so the game's own
    # command_* hooks fire (item-get popup, any other mod) exactly as if the event
    # granted it here. @params mimics a constant increase: see operate_value.
    # Guarded so the command's own broadcast hook doesn't re-broadcast.
    def self.on_loot_gain(packet)
      type, id, amount = packet.data.split(';')
      type = type.to_i; id = id.to_i; amount = amount.to_i
      return if amount <= 0
      $bsmp_applying_loot = true
      begin
        interp = Game_Interpreter.new
        case type
        when 0 then interp.bsmp_run_gain(:command_126, [id, 0, 0, amount])
        when 1 then interp.bsmp_run_gain(:command_127, [id, 0, 0, amount, false])
        when 2 then interp.bsmp_run_gain(:command_128, [id, 0, 0, amount, false])
        when 3 then interp.bsmp_run_gain(:command_125, [0, 0, amount])
        end
      ensure
        $bsmp_applying_loot = false
      end
    end

    # A peer earned a world-unique covenant token: grant our own copy. add_spirit is
    # idempotent (no dup); apply_fact's guard stops our own add_spirit hook re-broadcasting.
    def self.on_spirit_gain(packet)
      return if $game_party.nil? or not $game_party.respond_to?(:add_spirit)
      apply_fact { $game_party.add_spirit(packet.data.to_i) }
    end

    # Owner-driven mobs: apply the owner's positions to our copies of the moving
    # events, but only while we're NOT the owner of this map (otherwise the mobs are
    # ours to simulate). Each entry is "id,x,y,dir[,op,speed,trans,forming]"; the event
    # glides or snaps to it (see Game_Event#bsmp_apply_sync). Unknown ids are skipped.
    def self.on_mob_sync(packet)
      return if BSMP::World.map_owner_here?  # we're the source of this; ignore our echo
      return if not $game_map
      parts = packet.data.split(';')
      return if parts.empty?
      map_id = parts.shift.to_i
      return if map_id != $game_map.map_id # owner is on another map than us
      parts.each do |entry|
        f = entry.split(',')
        next if f.size < 4
        event = $game_map.events[f[0].to_i]
        next if not event
        opacity = f[4] ? f[4].to_i : nil
        speed   = f[5] ? f[5].to_i : nil
        transp  = f[6] ? f[6].to_i : nil
        event.bsmp_apply_sync(f[1].to_i, f[2].to_i, f[3].to_i, opacity, speed, transp)
        # Mirror the chase "!" state from the owner across the handoff boundary so the
        # mob doesn't visibly "calm down" between owners. @forming only exists on
        # symbol-encounter mobs; the rescue covers events without it.
        if f.size >= 8 and event.instance_variable_defined?(:@forming)
          event.instance_variable_set(:@forming, f[7].to_i == 1)
        end
      end
    end

    # Owner showed a balloon icon on an event (the enemy "!" notice and friends);
    # mirror it onto our copy. Setting balloon_id is read by Sprite_Character, so the
    # animation plays just as locally. Only applies to non-owners on the same map.
    def self.on_mob_balloon(packet)
      return if BSMP::World.map_owner_here?  # we're the source; ignore echo
      return if not $game_map
      map_id, event_id, balloon = packet.data.split(';')
      return if map_id.to_i != $game_map.map_id
      event = $game_map.events[event_id.to_i]
      event.balloon_id = balloon.to_i if event
    end

    # Owner erased an event (e.g. a defeated enemy removed itself after battle); erase
    # our copy too so it disappears in lockstep. erase() on a non-owner doesn't re-emit
    # (the hook only broadcasts on the owner).
    def self.on_mob_erase(packet)
      return if BSMP::World.map_owner_here?  # we're the source; ignore echo
      return if not $game_map
      map_id, event_id = packet.data.split(';')
      BSMP.debug_log { "recv MOB_ERASE map=#{map_id} ev=#{event_id} (mymap=#{$game_map.map_id})" }
      return if map_id.to_i != $game_map.map_id
      event = $game_map.events[event_id.to_i]
      event.erase if event
    end

    # --- live world-state facts (applied with the anti-echo guard) ---

    def self.on_switch_changed(packet)
      id, val = packet.data.split(';')
      apply_fact { $game_switches[id.to_i] = (val.to_i != 0) }
    end

    def self.on_variable_changed(packet)
      id, val = packet.data.split(';')
      apply_fact { $game_variables[id.to_i] = val.to_i }
    end

    def self.on_self_switch_changed(packet)
      map_id, event_id, ch, val = packet.data.split(';')
      # Debug-only: a world-snapshot apply / flag-heavy event sends these in bursts, and
      # BSMP.log is file I/O — logging each visibly stalls. (Pairs with the send-side gate.)
      BSMP.debug_log { "recv self_switch [#{map_id},#{event_id},#{ch}]=#{val}" }
      apply_fact { $game_self_switches[[map_id.to_i, event_id.to_i, ch]] = (val.to_i != 0) }
    end

    # Apply a received world fact without the setter hooks re-broadcasting it.
    def self.apply_fact
      $bsmp_applying_fact = true
      yield
    ensure
      $bsmp_applying_fact = false
    end

    # --- BSMP packet types (Reserved types for the core 0-2048) ---

    INVALID_PACKET = 0
    PLAYER_JOINED = 1
    # Format: "direction"
    PLAYER_MOVED = 2
    # Format: "x;y"
    PLAYER_CHANGED_POS = 3
    PLAYER_CHANGED_NICK = 4
    # Format: "speed"
    PLAYER_CHANGED_SPEED = 5
    # Format: "sprite_name;sprite_index;nickname"
    PLAYER_CHANGED_CHARACTER = 6
    # Format: "map_id;location_name"
    PLAYER_CHANGED_MAP = 7
    # Format: "horz_direction;vert_direction"
    PLAYER_MOVED_DIAG = 8
    PLAYER_LEAVED = 9

    # Unused
    SAVE_CONTENTS_PART = 10

    # Handshake / world-transfer control messages. Point-to-point host<->guest,
    # handled directly in Client/Server#on_packet_read (NOT relayed, NOT in HANDLERS).
    HANDSHAKE_HELLO   = 11
    HANDSHAKE_WELCOME = 12
    HANDSHAKE_REJECT  = 13
    WORLD_SNAPSHOT    = 14
    # Guest -> host: "I'm in-game now, send me the current world." Lets a guest that
    # joined from the title/menu pull a fresh snapshot the moment it loads in, instead
    # of relying on the (possibly never received, or pre-load) WELCOME-time snapshot.
    WORLD_REQUEST     = 20

    # Live world-state facts (shared switches/variables + all self-switches).
    SWITCH_CHANGED      = 15
    VARIABLE_CHANGED    = 16
    SELF_SWITCH_CHANGED = 17

    # A player's round-trip ping to the host (ms), self-reported by each guest.
    PLAYER_PING         = 18

    # Instanced loot: an event gave someone an item/gold; each peer grants its own
    # copy. data = "type;id;amount" (type 0=item 1=weapon 2=armor 3=gold).
    LOOT_GAIN           = 19

    # World-unique covenant token ("spirit"): granted via $game_party.add_spirit (a
    # Script call, NOT ChangeItems, so LOOT_GAIN misses it). When one player earns it
    # (covenant level-up, CE817) every peer gets their own copy. data = "spirit_id".
    SPIRIT_GAIN         = 52

    # Mid-battle battle-background change (event command 283 / script 180). Troop events
    # run only on the host, so a phase-change backdrop swap never reached guests. The host
    # mirrors it; the guest applies the same battleback. data = "bb1<US>bb2" (file names).
    BATTLE_BACK         = 53

    # Story transfer-follow: a co-op battle's aftermath (IfWin TransferPlayer, e.g. boss
    # victory or a kill that moves to another map) runs only in the interpreter of the
    # peer that ran the battle event — the others, pulled in as mute clients, never run
    # that branch and so stayed behind. That peer broadcasts the resolved transfer; every
    # other peer reserves the SAME one so the party moves together. data = "map;x;y;dir".
    STORY_TRANSFER      = 54

    # Host-driven mobs: the host's periodic position broadcast for every moving
    # event on its current map. data = "map_id;id,x,y,dir;id,x,y,dir;...". Guests on
    # that same map glide their event copies to match (see 1247 - BSMP Mobs.rb).
    MOB_SYNC            = 21

    # Host-driven balloon icon (e.g. the enemy "!" notice): the host showed a balloon
    # on an event; guests on that map show the same. data = "map_id;event_id;balloon".
    MOB_BALLOON         = 22

    # Host erased an event (e.g. a defeated symbol enemy after battle). erase() is
    # local (not a self-switch), so mirror it. data = "map_id;event_id".
    MOB_ERASE           = 23

    # --- co-op battle (step 6) ---
    # Battle lifecycle. The map owner announces its battle so non-owners on the SAME
    # map join as mute clients (BATTLE_START = "map_id;troop_id;escape") and the
    # authoritative end so they leave (BATTLE_END = "result"). The leading map_id in
    # BATTLE_START lets peers on OTHER maps (e.g. the lobby host on its own map) ignore
    # a battle they aren't part of. Handlers live in 1250 - BSMP Battle.rb (registered
    # into HANDLERS there). 26-39 reserved for the rest of the battle epic (snapshot,
    # ATB / HP / state facts, input request/response).
    BATTLE_START        = 24
    BATTLE_END          = 25 # Format: "result"

    # Host's periodic battler-state broadcast during a co-op battle, so a guest's mute
    # scene mirrors the screen tone + enemy HP/MP/ATB/states. data =
    # "r.g.b.gray;idx,hp,mp,ap,id:turns.id:turns;...": a leading screen-tone segment then
    # one entry per enemy (states as id:remaining-turns, dot-joined, empty = none).
    BATTLE_SYNC         = 26

    # Action replay (step 6.2 slice 2): host pushes the VISUALS of a resolved action
    # so the mute guest plays them without re-rolling. Enemy targets only for now
    # (the actor side is each guest's own party until the combined party, 6.3).
    # BATTLE_ANIM   = play an animation on enemy targets. data = "anim_id;mirror;idx,idx,...".
    # BATTLE_RESULT = per-enemy action result -> damage pop-up. data = "idx;hp;mp;tp;flags"
    #                 (flags bit0 missed, bit1 evaded, bit2 critical).
    BATTLE_ANIM         = 27
    BATTLE_RESULT       = 28

    # The host's BATTLE screen flashed / shook (Game_Screen#start_flash / start_shake on
    # $game_troop.screen) -> mirror it EXACTLY (variable per attack; never a fixed
    # preset). data: BATTLE_FLASH "r;g;b;a;duration", BATTLE_SHAKE "power;speed;duration".
    # The attack-animation's own flash/shake live in the animation shown on the actor
    # (not a Game_Screen call), so they arrive for free in 6.3 when it replays there.
    BATTLE_FLASH        = 29
    BATTLE_SHAKE        = 31

    # The host's enemy subject is about to act (the pre-attack white blink,
    # sprite_effect_type :whiten) -> play it on our copy. data = "idx".
    BATTLE_WHITEN       = 30

    # Combined party (step 6.3): a player sends a snapshot of one of its battle actors
    # so the host can build a proxy Game_Actor and put it in the fight. One packet per
    # actor; from_id = the owning player. data (see 1251 - BSMP Battle Party.rb):
    # "actor_id;name;char_name;char_idx;face_name;face_idx;mhp;mmp;atk;def;mat;mdf;agi;luk;hp;mp;tp;ap;states".
    BATTLE_ACTOR        = 32

    # Combined party state (step 6.3b): the host streams the authoritative HP/MP/ATB/
    # states of EVERY battler in the party (its own actors + every guest's proxy) so each
    # mute guest's combined party tracks the real fight — both the proxies it renders of
    # the others AND its own actor (whose damage is rolled on the host's proxy of it).
    # Keyed by (owner, actor_id), not index, so it's order-independent across peers.
    # data = "owner.actor_id,hp,mp,ap,id:turns.id:turns;...": one entry per party battler.
    BATTLE_PARTY_SYNC   = 33

    # Remote-turn input (step 6.4). When a guest's proxy reaches its ATB turn on the
    # host, the host asks the owning guest for its command instead of auto-resolving.
    # BATTLE_INPUT_REQUEST host->owner (point-to-point): data = "actor_id" (which of the
    # guest's actors). BATTLE_INPUT owner->host (reply): data = "actor_id;kind;obj_id;
    # target_index" — kind a=attack g=guard s=skill i=item, obj_id = skill/item id (0 for
    # attack/guard), target_index = index into $game_troop.members (opponent) or
    # $game_party.battle_members (friend), resolved by the action's scope on the host.
    BATTLE_INPUT_REQUEST = 34
    BATTLE_INPUT         = 35

    # --- map ownership (per-map authority registrar) ---------------------------
    # Per-map mob authority is handed out by the lobby host on a first-come-first-served
    # basis. Whoever claims a map becomes its "owner": it simulates the mobs locally,
    # streams MOB_SYNC, runs command_301 (battle start) on touch, and broadcasts the
    # outcome (SELF_SWITCH_CHANGED / MOB_ERASE / BATTLE_*). Everyone else on that map
    # (including the lobby host, if it's not the owner) puppets and acts as a mute client
    # for any battle. Lets two guests on a map without the host still play co-op (the
    # owner's battle rejoins the others), without loading every map onto the host.
    #
    # MAP_OWNERSHIP_REQUEST  peer->host  data = "map_id"  — "may I own this map?"
    # MAP_OWNERSHIP_REPLY    host->peer  data = "map_id;1|0[;snapshot]" — yes/no, with a
    #   cached mob snapshot appended on grant so the new owner resumes mid-state instead
    #   of resetting (forming flag included so the chase "!" persists across handoff).
    # MAP_OWNERSHIP_RELEASE  owner->host data = "map_id"  — "I left, reassign if anyone
    #   else is here". The host keeps the last relayed MOB_SYNC per map for exactly this.
    MAP_OWNERSHIP_REQUEST = 40
    MAP_OWNERSHIP_REPLY   = 41
    MAP_OWNERSHIP_RELEASE = 42

    # A non-host peer touched a hostile on its map and wants the host to start the
    # co-op battle for everyone. data = "troop_id;can_escape;can_lose". The host
    # runs the real Scene_Battle; the requester (and everyone else) joins as a mute
    # client via the normal BATTLE_START. After BATTLE_END, the requester's
    # Game_Interpreter#command_301 Fiber resumes with @branch[@indent] set, so the
    # event page's IfWin / IfEscape / IfLose branches run on the requester's side
    # (set_self_switch / common event) and propagate via the world-sync. This keeps
    # the host as the single battle authority even for battles triggered on a map
    # the host isn't standing on.
    BATTLE_REQUEST        = 43

    # Co-op death / scripted-loss mirror (step 6.5). The battle authority runs the
    # real event IfLose branch; when that branch calls a "shared" common event
    # (Config::SHARED_COMMON_EVENT_IDS — e.g. CE 12 = death), it broadcasts MIRROR_CE
    # so every other peer runs the SAME common event locally (everyone dies / sees
    # the same outcome). data = "common_event_id". A non-shared loss (a scripted
    # cutscene driven by switches, not a death CE) broadcasts nothing, so a guest no
    # longer wrongly dies on it. The mirrored run is loot-local (see 1246).
    MIRROR_CE             = 44

    # Consensus gate (step 6.7). A map event (boss fog, NG+ stone, ...) calls
    # bsmp_ready_gate: the acting player parks until EVERY player has reached and
    # confirmed the same gate. READY_GATE peer->host = "I'm ready for gate <id>";
    # READY_GATE_CANCEL peer->host = "I backed out"; READY_GATE_SYNC host->all =
    # "<id>;count;need;done" — the host is the single tally authority.
    READY_GATE            = 45
    READY_GATE_CANCEL     = 46
    READY_GATE_SYNC       = 47

    # In-battle dialogue sync + all-confirm barrier (step 6.8). Troop-event ShowText
    # runs only on the host (guests are mute, no troop events), so the host mirrors
    # each battle dialogue: BATTLE_MSG_SHOW host->all = "seq<US>face<US>idx<US>bg<US>
    # pos<US>line<US>line..." populates the guest's $game_message. The barrier lives in
    # Window_Message#input_pause: each peer that dismisses a dialogue sends
    # BATTLE_MSG_ACK peer->host = "seq"; the host tallies and, at all-confirmed, sends
    # BATTLE_MSG_CLOSE host->all = "seq" so everyone un-pauses together. Keyed by the
    # host-assigned seq (identical on every peer), so no fragile per-page counter.
    BATTLE_MSG_SHOW       = 48
    BATTLE_MSG_ACK        = 49
    BATTLE_MSG_CLOSE      = 50

    # Battle-log line mirror (step 6.8). The host's Window_BattleLog ("X strikes!",
    # "Y takes 120 damage", ...) is built by actions that only run on the host; the mute
    # guest's log stayed empty. The host mirrors each log mutation: BATTLE_LOG host->all =
    # "op<US>arg" where op is a=add_text r=replace_text c=clear b=back_to 1=back_one.
    BATTLE_LOG            = 51

    HANDLERS = {
      PLAYER_JOINED            => method(:on_player_joined),
      PLAYER_MOVED             => method(:on_player_moved),
      PLAYER_CHANGED_POS       => method(:on_player_changed_pos),
      PLAYER_CHANGED_SPEED     => method(:on_player_changed_speed),
      PLAYER_CHANGED_CHARACTER => method(:on_player_changed_character),
      PLAYER_CHANGED_MAP       => method(:on_player_changed_map),
      PLAYER_MOVED_DIAG        => method(:on_player_moved_diag),
      PLAYER_LEAVED            => method(:on_player_leaved),
      SAVE_CONTENTS_PART       => method(:on_save_contents_part),
      SWITCH_CHANGED           => method(:on_switch_changed),
      VARIABLE_CHANGED         => method(:on_variable_changed),
      SELF_SWITCH_CHANGED      => method(:on_self_switch_changed),
      PLAYER_PING              => method(:on_player_ping),
      LOOT_GAIN                => method(:on_loot_gain),
      SPIRIT_GAIN              => method(:on_spirit_gain),
      MOB_SYNC                 => method(:on_mob_sync),
      MOB_BALLOON              => method(:on_mob_balloon),
      MOB_ERASE                => method(:on_mob_erase),
    }
    # MAP_OWNERSHIP_REPLY is registered in 1205 - BSMP World.rb, pointing straight
    # at BSMP::World.on_map_ownership_reply (no Core wrapper needed).

  end

  class Packet

    # Serialized values delimiter, transferred in BasicNetworkPacket.data.
    # Needed to transfer multiple values in one packet.
    DATA_DELIMITER = ';'

    # this method should return unique packet identifier
    def self.type
      return Events::INVALID_PACKET
    end

    # this method should return array of values to be transferred
    def serialize
      raise NotImplementedError
    end

    # this method should return BasicNetworkPacket from its contents
    def serialize_raw
      data = serialize.join(DATA_DELIMITER)
      return BasicNetworkPacket.new(self.type, 0, data)
    end

    # this method should parse BasicNetworkPacket and return self
    def self.parse_raw(packet)
      args = packet.data.split(DATA_DELIMITER)
      return self.parse(packet, args)
    end

    # this method should parse args and return self instance
    def self.parse(packet, args)
      raise NotImplementedError
    end

  end

end # module BSMP

end # if Object.const_defined?(:SteamAPI)

end # not $imported["IDL-BSMP"]
