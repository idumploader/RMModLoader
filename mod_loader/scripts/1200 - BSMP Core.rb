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
#               BasicNetworkPacket), MLLocalizedStrings (100).
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

    # Steam ELobbyType (as the native create_lobby binding expects it). Default lobby
    # visibility when hosting; Settings.lobby_type defaults to this.
    LOBBY_ONLY_FRIENDS = 10

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
    SHARED_SWITCH_RANGES   = []
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
      2
    ]
    SHARED_COMMON_EVENT_IDS   = [
      12,  # Death
    ]

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
      :roster_key      => ModLoader::Keyboard::TAB,   # held key (ModLoader VK) for the roster overlay
      :debug           => false,                      # runtime diagnostic logging (BSMP.log / debug_log)
      :debug_packets   => false,                      # per-packet wire trace firehose (independent of :debug)
      # Co-op battle heartbeat watchdog: frames (~60/s) a mute guest waits without ANY
      # host battle state before assuming the host left its battle (missed BATTLE_END,
      # e.g. across an F12 reset) and bailing to the map. 0 disables it. Generous by
      # default so a host window-defocus (RGSS pauses unfocused, unless ModLoader keeps
      # the thread running) doesn't wrongly kick the guest.
      :battle_watchdog_frames => Config::BATTLE_STARVE_FRAMES,
      # How long (frames) the host waits for a guest's battle command before auto-acting
      # for it; also the length of the guest's on-screen turn timer (6.4).
      :battle_input_timeout_frames => Config::BATTLE_INPUT_TIMEOUT,
    }

    # Typed accessors over the backing store; setters edit the working copy only
    # (call #commit to persist — a settings menu does this on "Apply").
    DEFAULTS.each_key do |field|
      define_method(field)        { @data[field] }
      define_method("#{field}=")  { |value| @data[field] = value }
    end

    def initialize
      @data = open_backing
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

  # Runtime diagnostic log, off by default. Flip BSMP.settings.debug = true (e.g. on
  # both machines) to trace behaviour over the wire, then read the console.
  def self.log(msg)
    p "[BSMP] #{msg}" if settings.debug
  end

  # Lazy variant: the block is evaluated ONLY when debug is on, so a (frequently
  # interpolated, sometimes bursty) message string is never built in the hot path
  # when logging is off. Prefer over `log("...#{x}...") if settings.debug` — that
  # form still builds the string every call because Ruby evaluates args first.
  def self.debug_log
    p "[BSMP] #{yield}" if settings.debug
  end

  # Per-packet wire firehose, behind its own flag so plain :debug stays readable.
  # Fires on every packet (movement spam included) — keep block-form and opt-in.
  def self.debug_packet_log
    p "[BSMP] #{yield}" if settings.debug_packets
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

  # --- map / location naming ------------------------------------------------

  # Best human name for OUR current map: the lore display_name (the on-screen
  # banner) if set, else the editor tree name. Broadcast with PLAYER_CHANGED_MAP
  # so viewers show a real location without loading the peer's map.
  def self.current_location_name
    name = $game_map.display_name.to_s
    if name.empty? and $data_mapinfos and $data_mapinfos[$game_map.map_id]
      name = $data_mapinfos[$game_map.map_id].name.to_s
    end
    name
  end

  # PLAYER_CHANGED_MAP payload: "map_id;location_name".
  def self.current_map_payload
    "#{$game_map.map_id};#{current_location_name}"
  end

  # Local fallback name for an arbitrary map id (editor tree name); used when a
  # peer didn't send a name. "?" if unknown.
  def self.location_name(map_id)
    info = $data_mapinfos ? $data_mapinfos[map_id] : nil
    (info and info.name and not info.name.empty?) ? info.name : "?"
  end

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

  # --- host presence (host-driven mobs) -------------------------------------
  # Mobs are host-authoritative only on the map the host is currently on. A guest
  # uses these to decide whether to hand its moving events over to the host's
  # positions (host_here?) or keep simulating them locally (host elsewhere).

  def self.host_user_id
    ($bsmp_client and $bsmp_client.connected?) ? $bsmp_client.server_user_id : nil
  end

  # The host's remote-player character on this guest (carries the host's map_id).
  def self.host_character
    id = host_user_id
    (id and $bsmp_players) ? $bsmp_players[id] : nil
  end

  # True on a guest when the host is present on our current map, so the host is
  # simulating these mobs and we should puppet ours to its broadcasts.
  def self.host_here?
    return false if not guest?
    hc = host_character
    hc and $game_map and hc.map_id == $game_map.map_id
  end

  module Events

    def self.on_packet(packet)
      # packet.data is UTF-8 for free now — BasicNetworkPacket#data re-tags on every read
      # (see the reopen at the top of this file), so handlers never need force_encoding.
      handler = HANDLERS[packet.type]
      handler.call(packet) if handler
    end

    # Map ownership registrar reply (handled by BSMP::World, which holds the local
    # owner flag + snapshot apply). Plain delegation so the Events/HANDLERS table can
    # reference it the same way as the other on_* handlers.
    def self.on_map_ownership_reply(packet)
      BSMP::World.on_map_ownership_reply(packet)
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

    def self.on_player_moved(packet)
      return if not SceneManager.scene_is?(Scene_Map) # needs a loaded map (round_x_with_direction)
      dir = packet.data.to_i
      $bsmp_players.move_player_straight(packet.from_id, dir)
    end

    def self.on_player_changed_pos(packet)
      # No scene guard: positioning is plain data (moveto, no $game_map). Dropping it
      # off-map would lose a joiner's initial position until they next move.
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
    end

    def self.on_player_moved_diag(packet)
      return if not SceneManager.scene_is?(Scene_Map)
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
      MAP_OWNERSHIP_REPLY      => method(:on_map_ownership_reply),
    }

    NAMES = {
      PLAYER_JOINED => "PLAYER_JOINED",
      PLAYER_MOVED => "PLAYER_MOVED",
      PLAYER_CHANGED_NICK => "PLAYER_CHANGED_NICK",
    }

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
