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

  class Client

    attr_reader :lobby_id
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

    def update_player_data
      return if not $game_player.actor
      char_packet = BasicNetworkPacket.new(Events::PLAYER_CHANGED_CHARACTER, 0, "#{$game_player.character_name};#{$game_player.character_index};#{$game_player.actor.name}")
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_POS
      char_packet.data = "#{$game_player.x};#{$game_player.y}"
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_MAP
      char_packet.data = "#{$game_map.map_id}"
      send_packet(char_packet)

      char_packet.type = Events::PLAYER_CHANGED_SPEED
      char_packet.data = "#{$game_player.move_speed}"
      send_packet(char_packet)
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

      update_player_data
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
      char_packet.data = "#{$game_map.map_id}"
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
        return if find_client(user_id)
        channel_id = 0
        # channel_id = 1 if Config::DEBUG
        client = ServerClient.new(user_id, channel_id)
        add_client(client)
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
