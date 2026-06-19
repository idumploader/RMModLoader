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

    # Content gate: reject peers whose gameplay $data_* fingerprint differs (mods /
    # database mismatch). Set false to allow knowingly-different content.
    CHECK_DATA_HASH = true

    DEFAULT_SERVER_CHANNEL_ID = 0
    DEFAULT_SERVER_CLIENT_ID = 1

    LOBBY_ONLY_FRIENDS = 10

    LOBBY_CHAT_UPDATE_JOINED = 1

    CALL_RESULT_LOBBY_JOINED = 504
    CALL_RESULT_LOBBY_CREATED = 513

    CALLBACK_JOIN_REQUESTED = 333
    CALLBACK_LOBBY_ENTERED = 504
    CALLBACK_LOBBY_CHAT_UPDATE = 506

    SEND_FLAG_RELIABLE = 8

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
      dir = packet.data.to_i
      $bsmp_players.move_player_straight(packet.from_id, dir)
    end

    def self.on_player_changed_pos(packet)
      pos = packet.data.split(';')
      $bsmp_players.player_moveto(packet.from_id, pos[0].to_i, pos[1].to_i)
    end

    def self.on_player_changed_speed(packet)
      speed = packet.data.to_i

      # p "Player #{packet.from_id} changed move speed to #{speed}"
      $bsmp_players.set_player_speed(packet.from_id, speed)
    end

    def self.on_player_changed_character(packet)
      return if SceneManager.scene.class != Scene_Map
      character_name, character_index, nickname = packet.data.force_encoding("UTF-8").split(';')

      p "Player #{packet.from_id} changed sprite to #{character_name}/#{character_index}, nick to #{nickname}"
      $bsmp_players.set_player_character(packet.from_id, character_name, character_index.to_i, nickname)
    end

    def self.on_player_changed_map(packet)
      return if SceneManager.scene.class != Scene_Map
      map = packet.data.to_i

      p "Player #{packet.from_id} moved to map #{map}"
      $bsmp_players.set_player_map(packet.from_id, map)
    end

    def self.on_player_moved_diag(packet)
      return if SceneManager.scene.class != Scene_Map
      horz, vert = packet.data.split(';')

      $bsmp_players.move_player_diagonal(packet.from_id, horz.to_i, vert.to_i)
    end

    def self.on_save_contents_part(packet)

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
