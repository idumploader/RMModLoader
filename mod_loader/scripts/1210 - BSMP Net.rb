#==============================================================================
# BSMP Net — part 2/5: lobby + transport. Client (joins a lobby, sends/reads on
# its channel), Server (owns the lobby, relays packets between clients) and the
# ServerClient record. See 1200 - BSMP Core.rb.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Net"]
$imported["IDL-BSMP-Net"] = "1.0"

if defined?(BSMP)

module BSMP

  # Handshake payloads + validation. The HELLO is a small ';'-delimited string the
  # guest sends right after entering the lobby; the host validates it (mutual
  # version acceptance + game + content hash) and answers WELCOME (+ world snapshot)
  # or REJECT. See spec section 4.
  module Handshake

    DELIM = ';'

    # Our HELLO: own version, the peer-version range we accept, game title, and a
    # local fingerprint of the gameplay database.
    def self.hello
      [
        Config::MAJOR_VERSION,
        Config::MINOR_VERSION,
        Config::ACCEPTED_MINOR_MIN,
        Config::ACCEPTED_MINOR_MAX,
        game_title,
        data_hash,
      ].join(DELIM)
    end

    def self.parse(data)
      a = data.dup.force_encoding("UTF-8").split(DELIM)
      {
        :major      => a[0].to_i,
        :minor      => a[1].to_i,
        :accept_min => a[2].to_i,
        :accept_max => a[3].to_i,
        :game_title => a[4].to_s,
        :data_hash  => a[5].to_i,
      }
    end

    # => [accepted(bool), reason(String)]
    def self.validate(peer)
      if peer[:major] != Config::MAJOR_VERSION
        return [false, "protocol major #{peer[:major]} != #{Config::MAJOR_VERSION}"]
      end
      # Mutual MINOR acceptance: peer must accept our minor AND we must accept theirs.
      peer_accepts_us = peer[:accept_min] <= Config::MINOR_VERSION && Config::MINOR_VERSION <= peer[:accept_max]
      we_accept_peer  = Config::ACCEPTED_MINOR_MIN <= peer[:minor] && peer[:minor] <= Config::ACCEPTED_MINOR_MAX
      if not (peer_accepts_us and we_accept_peer)
        return [false, "minor #{peer[:minor]} not mutually accepted (ours #{Config::MINOR_VERSION})"]
      end
      if peer[:major] != Config::MAJOR_VERSION || peer[:minor] != Config::MINOR_VERSION
        p "BSMP handshake: minor differs (peer #{peer[:major]}.#{peer[:minor]}, us #{Config::MAJOR_VERSION}.#{Config::MINOR_VERSION}) but mutually accepted"
      end
      if Config::CHECK_GAME and peer[:game_title] != game_title
        return [false, "different game (peer '#{peer[:game_title]}' vs '#{game_title}')"]
      end
      if Config::CHECK_DATA_HASH and peer[:data_hash] != data_hash
        return [false, "content/mod mismatch (data hash)"]
      end
      [true, "ok"]
    end

    def self.game_title
      $data_system ? $data_system.game_title.to_s : ""
    end

    # crc32 of a local Marshal.dump of the gameplay-relevant database. Marshal is
    # used ONLY locally here (never load()ed from a peer); the wire carries just the
    # resulting integer. Cached — the database is constant for the session.
    def self.data_hash
      # NOT cached: some games (incl. BS2) patch $data_* at runtime on save-load /
      # new-game, so the fingerprint changes with game state. Caching it would make
      # a stale (e.g. title-screen) hash sticky and wrongly reject a later in-game
      # join.
      Zlib.crc32(Marshal.dump([
        $data_actors, $data_classes, $data_skills, $data_items,
        $data_weapons, $data_armors, $data_enemies, $data_troops,
        $data_states, $data_system, $data_common_events,
      ]))
    end

  end

  class Client

    attr_reader :lobby_id
    attr_reader :server_user_id
    attr_accessor :channel_id
    attr_accessor :read_channel_id

    def initialize
      @lobby_joined_callresult = SteamCCallResult.new(Config::CALL_RESULT_LOBBY_JOINED)
      @lobby_joined_callresult.register(self, :on_lobby_enter)
      @lobby_join_requested_callback = SteamCCallback.new(Config::CALLBACK_JOIN_REQUESTED, self, :on_lobby_join_requested)
      @lobby_chat_update_callback = SteamCCallback.new(Config::CALLBACK_LOBBY_CHAT_UPDATE, self, :on_lobby_chat_update)

      @channel_id = 0
      @read_channel_id = 0
      @server_user_id = nil
      @max_read_packets = 10
      @handshake_state = :idle # :idle -> :hello_sent -> :accepted / :rejected
      @pending_world = nil     # host snapshot awaiting a moment when we're in-game
    end

    def join_lobby(lobby_id)
      return false if not initted?
      SteamAPI.join_lobby(lobby_id, @lobby_joined_callresult)
    end

    def leave_lobby
      return false if not initted? or not @lobby_id
      return if not SteamAPI.leave_lobby(@lobby_id)
      @lobby_id = nil
      @server_user_id = nil
      @handshake_state = :idle
      $bsmp_players.clear # drop everyone's sprites when we leave the session
    end

    def send_packet(packet)
      return if not initted? or not connected?
      Wire.send_framed(@server_user_id, @channel_id, packet, Config::SEND_FLAG_RELIABLE)
    end

    def read_packets
      return if not initted? or not connected?
      SteamAPI.read_basic_packets(@read_channel_id, @max_read_packets, self, :on_packet_read)
    end

    def initted?
      return Object.const_defined?(:SteamAPI)
    end

    def connected?
      return @server_user_id != nil
    end

    # Announce our full state to the host. Returns false (didn't send) until we're
    # actually in-game — a guest that joined from the title has no actor / no loaded
    # map yet. ensure_announced retries until this goes through.
    def update_player_data
      return false if not $game_player.actor
      char_packet = BasicNetworkPacket.new(Events::PLAYER_CHANGED_CHARACTER, 0, "#{$game_player.character_name};#{$game_player.character_index};#{$game_player.actor.name}")
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_POS
      char_packet.data = "#{$game_player.x};#{$game_player.y}"
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_MAP
      char_packet.data = BSMP.current_map_payload
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_SPEED
      char_packet.data = "#{$game_player.move_speed}"
      send_packet(char_packet)
      true
    end

    # Per-frame upkeep after joining: announce ourselves once we load in, and
    # apply the host's world snapshot once we're actually in-game. Both are
    # retried each frame because a guest that accepted the handshake from the
    # title has no actor / no world objects yet.
    def ensure_announced
      return if not connected?
      @handshake_state = :ready if @handshake_state != :ready and update_player_data
      apply_pending_world
    end

    # Adopt the host's world. Deferred until World.ready? so it lands AFTER any
    # DataManager.load_game (a guest joining from the menu then loading a save
    # would otherwise have the save's load() overwrite an early-applied world).
    # Re-attempted every frame from ensure_announced until we're in-game, then
    # consumed once (success, or a format-mismatch skip).
    def apply_pending_world
      return if not @pending_world
      return if not World.ready? # not in-game yet — keep pending, retry next frame
      applied = World.load(@pending_world)
      p "World snapshot #{applied ? 'applied' : 'skipped'} (#{@pending_world.bytesize} B)"
      @pending_world = nil
    end

    private

    def on_lobby_enter(result, lobby_id, failure)
      return p "Failed to enter lobby: #{lobby_id}" if failure and result != 1
      if result != 1
        @lobby_id = nil
        return
      end

      p "Entered lobby, result: #{result}, id: #{lobby_id}"
      @lobby_id = lobby_id
      @server_user_id = SteamAPI.get_lobby_owner(lobby_id)

      # Don't announce ourselves yet — first do the handshake. We send player data
      # only once the host accepts and we've adopted its world (see handle_welcome).
      send_hello
    end

    def send_hello
      @handshake_state = :hello_sent
      send_packet(BasicNetworkPacket.new(Events::HANDSHAKE_HELLO, 0, Handshake.hello))
    end

    def handle_welcome(packet)
      @handshake_state = :accepted
      p "Handshake accepted by host"
      # Announce now if we're already in-game; otherwise ensure_announced retries
      # each frame until we load in (joined from the title).
      @handshake_state = :ready if update_player_data
    end

    def handle_world_snapshot(packet)
      # Cache the blob; apply now if we're already in-game, otherwise ensure_announced
      # applies it once we load in (and so AFTER any save-load that would clobber it).
      @pending_world = packet.data
      apply_pending_world
    end

    def handle_reject(packet)
      @handshake_state = :rejected
      p "Connection rejected by host: #{packet.data}"
      leave_lobby
    end

    def on_lobby_chat_update(lobby_id, update_enum, user_id, failure)
      return if failure or not connected?
      return if update_enum <= 1 or user_id != @server_user_id
      p "Server owner left"

      leave_lobby
    end

    def on_lobby_join_requested(lobby_id, requestor_id, failure)
      return if failure
      p "User #{requestor_id} requested to join to #{lobby_id}"
      join_lobby(lobby_id)
    end

    def on_packet_read(user_id, packet)
      packet.data = Wire.unpack(packet.data)
      case packet.type
      when Events::HANDSHAKE_WELCOME
        return handle_welcome(packet)
      when Events::HANDSHAKE_REJECT
        return handle_reject(packet)
      when Events::WORLD_SNAPSHOT
        return handle_world_snapshot(packet) # binary blob — don't log its data
      end
      p "Client got packet from #{packet.from_id}, type=#{packet.type}, data=#{packet.data}"
      Events.on_packet(packet)
    end

  end

  class ServerClient

    attr_accessor :user_id
    attr_accessor :channel_id

    def initialize(user_id, channel_id)
      @user_id = user_id
      @channel_id = channel_id
    end

  end

  class Server

    attr_accessor :channel_id
    attr_reader :lobby_id

    attr_accessor :clients

    def initialize
      @lobby_created_callresult = SteamCCallResult.new(Config::CALL_RESULT_LOBBY_CREATED)
      @lobby_created_callresult.register(self, :on_lobby_created)
      @lobby_chat_update_callback = SteamCCallback.new(Config::CALLBACK_LOBBY_CHAT_UPDATE, self, :on_lobby_chat_update)
      @lobby_join_requested_callback = SteamCCallback.new(Config::CALLBACK_JOIN_REQUESTED, self, :on_lobby_join_requested)

      @channel_id = 0
      @server_user_id = nil
      @clients = []
      @max_read_packets = 10
      @running = false
    end

    def create_lobby(lobby_type, max_players)
      return false if not initted?
      return SteamAPI.create_lobby(lobby_type, max_players, @lobby_created_callresult)
    end

    def leave_lobby
      return false if not initted? or not @lobby_id
      return if not SteamAPI.leave_lobby(@lobby_id)
      @lobby_id = nil
      @server_user_id = nil
      @running = false
      @clients.clear
      $bsmp_players.clear
    end

    def get_lobby_owner
      return nil if not @lobby_id
      return SteamAPI.get_lobby_owner(@lobby_id)
    end

    def send_packet(packet)
      return if not initted? or not running?
      packet.from_id = @server_user_id
      send_packet_to_all(packet)
    end

    def send_packet_to(client, packet)
      return if not initted? or not running?
      Wire.send_framed(client.user_id, client.channel_id, packet, Config::SEND_FLAG_RELIABLE)
    end

    def send_packet_to_all(packet)
      return if not initted? or not running?
      @clients.each do |client|
        send_packet_to(client, packet)
      end
    end

    def send_packet_to_all_except(packet, except_client)
      return if not initted? or not running?
      @clients.each do |client|
        next if client.user_id == except_client.user_id
        send_packet_to(client, packet)
      end
    end

    def read_packets
      return if not initted? or not running?
      SteamAPI.read_basic_packets(@channel_id, @max_read_packets, self, :on_packet_read)
    end

    def initted?
      return Object.const_defined?(:SteamAPI)
    end

    def running?
      return @running
    end

    def add_client(client)
      @clients.push(client)
      send_client_joined(client)
      send_joined_data_to_client(client)
    end

    # Validate a guest's HELLO and either onboard it (WELCOME + world snapshot +
    # normal join) or reject it with a reason. Never relayed to other clients.
    def handle_hello(user_id, packet)
      peer = Handshake.parse(packet.data)
      ok, reason = Handshake.validate(peer)
      if not ok
        p "Rejecting #{user_id}: #{reason}"
        send_control(user_id, Events::HANDSHAKE_REJECT, reason)
        return
      end
      return if find_client(user_id) # duplicate HELLO, already onboarded
      p "Accepting #{user_id}"
      send_control(user_id, Events::HANDSHAKE_WELCOME, "")
      send_world_snapshot(user_id)
      # Admit last: registers the client, announces the join to everyone and pushes
      # the host's own player data to the newcomer.
      add_client(ServerClient.new(user_id, @channel_id))
    end

    # Send a point-to-point control packet to a user that may not be a client yet.
    def send_control(user_id, type, data)
      return if not running?
      target = ServerClient.new(user_id, @channel_id)
      send_packet_to(target, BasicNetworkPacket.new(type, @server_user_id, data))
    end

    def send_world_snapshot(user_id)
      return if not World.ready?
      blob = World.dump
      target = ServerClient.new(user_id, @channel_id)
      send_packet_to(target, BasicNetworkPacket.new(Events::WORLD_SNAPSHOT, @server_user_id, blob))
      p "Sent world snapshot to #{user_id} (#{blob.bytesize} B raw)"
    end

    def send_joined_data_to_client(client)
      char_packet = BasicNetworkPacket.new(Events::PLAYER_JOINED, @server_user_id, $game_player.actor.name)
      send_packet_to(client, char_packet)

      char_packet.type = Events::PLAYER_CHANGED_CHARACTER
      char_packet.data = "#{$game_player.character_name};#{$game_player.character_index};#{$game_player.actor.name}"
      send_packet_to(client, char_packet)

      char_packet.type = Events::PLAYER_CHANGED_POS
      char_packet.data = "#{$game_player.x};#{$game_player.y}"
      send_packet_to(client, char_packet)

      char_packet.type = Events::PLAYER_CHANGED_MAP
      char_packet.data = BSMP.current_map_payload
      send_packet_to(client, char_packet)

      char_packet.type = Events::PLAYER_CHANGED_SPEED
      char_packet.data = "#{$game_player.move_speed}"
      send_packet_to(client, char_packet)
    end

    def delete_client(client)
      @clients.delete(client)
      send_client_leaved(client)
    end

    def find_client(user_id)
      return @clients.find do |client|
        client.user_id == user_id
      end
    end

    def send_client_joined(client)
      packet = BasicNetworkPacket.new(Events::PLAYER_JOINED, client.user_id, "")
      send_packet_to_all_except(packet, client)
      Events.on_packet(packet)
    end

    def send_client_leaved(client)
      packet = BasicNetworkPacket.new(Events::PLAYER_LEAVED, client.user_id, "")
      send_packet_to_all_except(packet, client)
      Events.on_packet(packet)
    end

    private

    def on_lobby_created(result, lobby_id, failure)
      return p "Failed to create lobby" if failure
      p "Created lobby, result: #{result}, id: #{lobby_id}"
      @lobby_id = lobby_id
      @server_user_id = SteamAPI.get_lobby_owner(lobby_id)
      @running = true
    end

    def on_lobby_chat_update(lobby_id, update_enum, user_id, failure)
      return if failure or not running?
      p "User #{user_id} changed lobby #{lobby_id}: #{update_enum}"

      return if update_enum == 0
      if update_enum == Config::LOBBY_CHAT_UPDATE_JOINED
        # Admission is deferred to the handshake: the client is added only after a
        # valid HELLO (see handle_hello). Here we just note the lobby join.
        p "User #{user_id} entered the lobby; awaiting handshake"
      else
        client = find_client(user_id)
        return if not client
        delete_client(client)
      end
    end

    def on_lobby_join_requested(lobby_id, requestor_id, failure)
      return if failure or not running?
      p "User #{requestor_id} requested to join to #{lobby_id}. Closing lobby..."
      leave_lobby
    end

    def on_packet_read(user_id, packet)
      packet.from_id = user_id
      packet.data = Wire.unpack(packet.data)
      if packet.type == Events::HANDSHAKE_HELLO
        return handle_hello(user_id, packet) # control message: validate, never relay
      end
      p "Got packet from #{user_id}, type=#{packet.type}, data=#{packet.data}"
      # p "Got packet from #{user_id}. type=#{Events::NAMES[packet.type]}, data=#{packet.data}"
      # Relay carries the plaintext data; send_packet_to re-frames per hop.
      client = find_client(user_id)
      if client
        send_packet_to_all_except(packet, client)
      else
        send_packet_to_all(packet)
      end
      Events.on_packet(packet)
    end

  end

  module Manager

  end

end # module BSMP

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Net"]
