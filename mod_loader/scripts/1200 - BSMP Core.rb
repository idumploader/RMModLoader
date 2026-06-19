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
    SHARED_SWITCH_IDS      = []
    SHARED_VARIABLE_RANGES = []
    SHARED_VARIABLE_IDS    = []

    # --- Host-driven mobs (step 4) ---
    # The host re-broadcasts the positions of all moving events on its current map
    # every this many frames; guests on that map glide their copies to match. Small
    # = smoother but chattier (zlib + "only movers" keep it cheap).
    MOB_SYNC_INTERVAL = 4
    # Tiles of position error before a guest hard-snaps a mob instead of gliding
    # (teleport, map seam, first sync). Mirrors the remote-player SNAP_DISTANCE.
    MOB_SNAP_DISTANCE = 3

  end

  # Runtime, user-changeable preferences — as opposed to Config, which is fixed
  # protocol / wire / Steam-enum values. A future in-game settings menu flips these
  # live (host lobby visibility, the strict content-hash gate, the roster key, ...);
  # they default to the previous constants so behaviour is unchanged. Access the
  # singleton via BSMP.settings. to_h / update give a future menu a load/save hook.
  class Settings
    attr_accessor :check_game       # reject a peer whose game (title) differs
    attr_accessor :check_data_hash  # strict gameplay-database fingerprint gate
    attr_accessor :lobby_type       # Steam ELobbyType handed to create_lobby when hosting
    attr_accessor :max_players      # lobby capacity when hosting
    attr_accessor :roster_key       # held key (ModLoader VK) for the roster overlay

    def initialize
      reset
    end

    def reset
      @check_game      = true
      @check_data_hash = false
      @lobby_type      = Config::LOBBY_ONLY_FRIENDS
      @max_players     = 10
      @roster_key      = ModLoader::Keyboard::TAB
      self
    end

    def to_h
      {
        :check_game      => @check_game,
        :check_data_hash => @check_data_hash,
        :lobby_type      => @lobby_type,
        :max_players     => @max_players,
        :roster_key      => @roster_key,
      }
    end

    # Apply a subset of keys (e.g. loaded from disk by a future settings menu);
    # unknown keys are ignored so an older save can't crash a newer build.
    def update(hash)
      hash.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
      self
    end
  end

  def self.settings
    @settings ||= Settings.new
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
      flags = data.getbyte(0)
      body = data[1, data.bytesize - 1] || ""
      body.force_encoding("ASCII-8BIT")
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

  # --- shared world-state classification (live sync) ------------------------
  # self-switches are always shared, so they have no predicate.

  def self.shared_switch?(id)
    Config::SHARED_SWITCH_IDS.include?(id) or
      Config::SHARED_SWITCH_RANGES.any? { |r| r.include?(id) }
  end

  def self.shared_variable?(id)
    Config::SHARED_VARIABLE_IDS.include?(id) or
      Config::SHARED_VARIABLE_RANGES.any? { |r| r.include?(id) }
  end

  # An event page is "host-owned world progression" (a guest must not run its
  # autorun/parallel) when its activating condition hinges on a synced flag: any
  # self-switch (all shared), or a shared switch/variable. Takes a page condition
  # (RPG::Event::Page::Condition) so it's pure and unit-testable.
  def self.world_owned_condition?(c)
    return true if c.self_switch_valid
    return true if c.switch1_valid and shared_switch?(c.switch1_id)
    return true if c.switch2_valid and shared_switch?(c.switch2_id)
    return true if c.variable_valid and shared_variable?(c.variable_id)
    false
  end

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
      handler = HANDLERS[packet.type]
      handler.call(packet) if handler
    end

    def self.on_player_joined(packet)
      p "Player #{packet.from_id} joined"
      $bsmp_players.add(packet.from_id, packet.data)
    end

    def self.on_player_leaved(packet)
      p "Player #{packet.from_id} leaved"
      $bsmp_players.delete(packet.from_id)
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

      p "Player #{packet.from_id} changed sprite to #{character_name}/#{character_index}, nick to #{nickname}"
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

      p "Player #{packet.from_id} moved to map #{map} (#{loc})"
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

    # Host-driven mobs: apply the host's positions to our copies of the moving
    # events, but only while we're a guest on the host's current map (otherwise the
    # mobs are ours to simulate). Each entry is "id,x,y,dir"; the event glides or
    # snaps to it (see Game_Event#bsmp_apply_sync). Unknown ids are skipped.
    def self.on_mob_sync(packet)
      return if not BSMP.guest?
      return if not $game_map
      parts = packet.data.split(';')
      return if parts.empty?
      map_id = parts.shift.to_i
      return if map_id != $game_map.map_id # host is on another map than us
      parts.each do |entry|
        f = entry.split(',')
        next if f.size < 4
        event = $game_map.events[f[0].to_i]
        event.bsmp_apply_sync(f[1].to_i, f[2].to_i, f[3].to_i) if event
      end
    end

    # Host showed a balloon icon on an event (the enemy "!" notice and friends);
    # mirror it onto our copy. Setting balloon_id is read by Sprite_Character, so the
    # animation plays just as locally. Only while a guest on the host's map.
    def self.on_mob_balloon(packet)
      return if not BSMP.guest?
      return if not $game_map
      map_id, event_id, balloon = packet.data.split(';')
      return if map_id.to_i != $game_map.map_id
      event = $game_map.events[event_id.to_i]
      event.balloon_id = balloon.to_i if event
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
      apply_fact { $game_self_switches[[map_id.to_i, event_id.to_i, ch]] = (val.to_i != 0) }
    end

    # Apply a received world fact without the setter hooks re-broadcasting it.
    def self.apply_fact
      $bsmp_applying_fact = true
      yield
    ensure
      $bsmp_applying_fact = false
    end

    INVALID_PACKET = 0
    PLAYER_JOINED = 1
    PLAYER_MOVED = 2
    PLAYER_CHANGED_POS = 3
    PLAYER_CHANGED_NICK = 4
    PLAYER_CHANGED_SPEED = 5
    PLAYER_CHANGED_CHARACTER = 6
    PLAYER_CHANGED_MAP = 7
    PLAYER_MOVED_DIAG = 8
    PLAYER_LEAVED = 9

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

    # Host-driven mobs: the host's periodic position broadcast for every moving
    # event on its current map. data = "map_id;id,x,y,dir;id,x,y,dir;...". Guests on
    # that same map glide their event copies to match (see 1247 - BSMP Mobs.rb).
    MOB_SYNC            = 21

    # Host-driven balloon icon (e.g. the enemy "!" notice): the host showed a balloon
    # on an event; guests on that map show the same. data = "map_id;event_id;balloon".
    MOB_BALLOON         = 22

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
      MOB_SYNC                 => method(:on_mob_sync),
      MOB_BALLOON              => method(:on_mob_balloon),
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
