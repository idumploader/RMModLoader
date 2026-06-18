#==============================================================================
# BSMP — Steam peer-to-peer multiplayer framework: lobby create/join, client/
# server messaging, remote-player sprites with nicknames, and synced state
# (position, movement, character, map, speed).
#
# Console commands:
#   make_server(type, max_players)   make_test_client    make_test_player
#   delete_test_player               send_c2s_packet(type, data)
#   read_s2c_packets                 set_skin(actor_id)  set_nick(nick)
#   show_test_window                 mech
#
# Dependencies: Steam runtime (SteamUserStatsLite, SteamAPI, SteamCCallResult,
#               SteamCCallback, BasicNetworkPacket), MLLocalizedStrings (100).
# Gate: only loads when SteamUserStatsLite and SteamAPI are defined.
# Defines: BSMPConfig/Events/Client/Server/ServerClient, BSMPPlayer_Character,
#          BSMPPlayers, BSMP_Window, BSMPProgress_Window; $bsmp_* globals.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP"]
$imported["IDL-BSMP"] = "1.0"


if not (Object.const_defined?(:SteamUserStatsLite) and Object.const_defined?(:SteamAPI))
p "Multiplayer isn't available"
else
# --- BSMP DEFINITIONS ---

class BSMPCallback

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

module BSMPConfig

  DEBUG = false

  MAJOR_VERSION = 0
  MINOR_VERSION = 2

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

# --- BSMP EVENTS ---

module BSMPEvents

  def self.on_packet(packet)
    handler = BSMPEvents::HANDLERS[packet.type]
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

  HANDLERS = {
    PLAYER_JOINED        => BSMPEvents.method(:on_player_joined),
    PLAYER_MOVED        => BSMPEvents.method(:on_player_moved),
    PLAYER_CHANGED_POS      => BSMPEvents.method(:on_player_changed_pos),
    PLAYER_CHANGED_SPEED    => BSMPEvents.method(:on_player_changed_speed),
    PLAYER_CHANGED_CHARACTER  => BSMPEvents.method(:on_player_changed_character),
    PLAYER_CHANGED_MAP      => BSMPEvents.method(:on_player_changed_map),
    PLAYER_MOVED_DIAG      => BSMPEvents.method(:on_player_moved_diag),
    PLAYER_LEAVED        => BSMPEvents.method(:on_player_leaved),
    SAVE_CONTENTS_PART      => BSMPEvents.method(:on_save_contents_part),
  }

  NAMES = {
    PLAYER_JOINED => "PLAYER_JOINED",
    PLAYER_MOVED => "PLAYER_MOVED",
    PLAYER_CHANGED_NICK => "PLAYER_CHANGED_NICK",
  }
end

class BSMPPacket

  # Serialized values delimiter,
  # that is transferred in BasicNetworkPacket.data field
  # It's needed to transfer multiple values in one packet
  DATA_DELIMITER = ';'

  # this method should return unique packet identifier
  def self.type
    return BSMPEvents::INVALID_PACKET
  end

  # this method should return array of values to be transferred
  def serialize
    raise NotImplementedError
  end

  # this method should return BasicNetworkPacket from it's contents
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

# --- BSMP CLIENT/SERVER ---

class BSMPClient

  attr_reader :lobby_id
  attr_accessor :channel_id
  attr_accessor :read_channel_id

  def initialize
    @lobby_joined_callresult = SteamCCallResult.new(BSMPConfig::CALL_RESULT_LOBBY_JOINED)
    @lobby_joined_callresult.register(self, :on_lobby_enter)
    @lobby_join_requested_callback = SteamCCallback.new(BSMPConfig::CALLBACK_JOIN_REQUESTED, self, :on_lobby_join_requested)
    @lobby_chat_update_callback = SteamCCallback.new(BSMPConfig::CALLBACK_LOBBY_CHAT_UPDATE, self, :on_lobby_chat_update)

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
    SteamAPI.send_basic_packet(@server_user_id, @channel_id, packet, BSMPConfig::SEND_FLAG_RELIABLE)
  end

  def read_packets
    return if not initted? or not connected?
    SteamAPI.read_basic_packets(@read_channel_id, @max_read_packets, self, :on_packet_read)
  end

  def initted?
    return SteamUserStatsLite.instance.initted?
  end

  def connected?
    return @server_user_id != nil
  end

  def update_player_data
    return if not $game_player.actor
    char_packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_CHANGED_CHARACTER, 0, "#{$game_player.character_name};#{$game_player.character_index};#{$game_player.actor.name}")
    send_packet(char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_POS
    char_packet.data = "#{$game_player.x};#{$game_player.y}"
    send_packet(char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_MAP
    char_packet.data = "#{$game_map.map_id}"
    send_packet(char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_SPEED
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
    p "Client got packet from #{packet.from_id}, type=#{packet.type}, data=#{packet.data}"
    BSMPEvents.on_packet(packet)
  end

end

class BSMPServerClient

  attr_accessor :user_id
  attr_accessor :channel_id

  def initialize(user_id, channel_id)
    @user_id = user_id
    @channel_id = channel_id
  end
end

class BSMPServer

  attr_accessor :channel_id
  attr_reader :lobby_id

  attr_accessor :clients

  def initialize
    @lobby_created_callresult = SteamCCallResult.new(BSMPConfig::CALL_RESULT_LOBBY_CREATED)
    @lobby_created_callresult.register(self, :on_lobby_created)
    @lobby_chat_update_callback = SteamCCallback.new(BSMPConfig::CALLBACK_LOBBY_CHAT_UPDATE, self, :on_lobby_chat_update)
    @lobby_join_requested_callback = SteamCCallback.new(BSMPConfig::CALLBACK_JOIN_REQUESTED, self, :on_lobby_join_requested)

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
    SteamAPI.send_basic_packet(client.user_id, client.channel_id, packet, BSMPConfig::SEND_FLAG_RELIABLE)
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
    return SteamUserStatsLite.instance.initted?
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
    char_packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_JOINED, @server_user_id, $game_player.actor.name)
    send_packet_to(client, char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_CHARACTER
    char_packet.data = "#{$game_player.character_name};#{$game_player.character_index};#{$game_player.actor.name}"
    send_packet_to(client, char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_POS
    char_packet.data = "#{$game_player.x};#{$game_player.y}"
    send_packet_to(client, char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_MAP
    char_packet.data = "#{$game_map.map_id}"
    send_packet_to(client, char_packet)

    char_packet.type = BSMPEvents::PLAYER_CHANGED_SPEED
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
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_JOINED, client.user_id, "")
    send_packet_to_all_except(packet, client)
    BSMPEvents.on_packet(packet)
  end

  def send_client_leaved(client)
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_LEAVED, client.user_id, "")
    send_packet_to_all_except(packet, client)
    BSMPEvents.on_packet(packet)
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
    if update_enum == BSMPConfig::LOBBY_CHAT_UPDATE_JOINED
      return if find_client(user_id)
      channel_id = 0
      # channel_id = 1 if BSMPConfig::DEBUG
      client = BSMPServerClient.new(user_id, channel_id)
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
    p "Got packet from #{user_id}, type=#{packet.type}, data=#{packet.data}"
    # p "Got packet from #{user_id}. type=#{BSMPEvents::NAMES[packet.type]}, data=#{packet.data}"
    packet.from_id = user_id
    client = find_client(user_id)
    if client
      send_packet_to_all_except(packet, client)
    else
      send_packet_to_all(packet)
    end
    BSMPEvents.on_packet(packet)
  end

end

module BSMPManager

end

# --- BSMP PLAYERS ---

class BSMPPlayer_Character < Game_Character

  attr_reader :player_id
  attr_accessor :character_name
  attr_accessor :character_index
  attr_accessor :map_id
  attr_accessor :move_speed

  def initialize(player_id, sprite_name, nickname)
    super()
    @player_id = player_id
    @character_name = sprite_name
    @character_index = 0
    @nickname = nickname
    @map_id = 0
  end

  def refresh
    super
  end

  def move_to_real(x, y)
    @real_x = x
    @real_y = y
  end
end

class BSMPPlayers

  attr_accessor :bsmp_players

  def initialize
    @bsmp_players ||= {}
  end

  def add(player_id, nickname)
    return if @bsmp_players.key?(player_id)
    new_character = BSMPPlayer_Character.new(player_id, "$アリス", nickname)
    @bsmp_players[player_id] = new_character

    SceneManager.scene.spriteset.add_player(new_character) if SceneManager.scene.class == Scene_Map
  end

  def delete(player_id)
    return if not @bsmp_players.key?(player_id)
    character = @bsmp_players.delete(player_id)

    SceneManager.scene.spriteset.delete_player(character) if SceneManager.scene.class == Scene_Map
  end

  def [](player_id)
    return @bsmp_players[player_id]
  end

  def move_player_real(player_id, x, y)
    return if not @bsmp_players.key?(player_id)
    @bsmp_players[player_id].move_to_real(x, y)
  end

  def move_player_straight(player_id, d, turn_ok = true)
    return if not @bsmp_players.key?(player_id)
    player = @bsmp_players[player_id]
    player.move_straight(d, turn_ok) if not player.moving?
  end

  def move_player_diagonal(player_id, horz, vert)
    return if not @bsmp_players.key?(player_id)
    player = @bsmp_players[player_id]
    player.move_diagonal(horz, vert) if not player.moving?
  end

  def player_moveto(player_id, x, y)
    return if not @bsmp_players.key?(player_id)
    @bsmp_players[player_id].moveto(x, y)
  end

  def set_player_character(player_id, character_name, character_index, nickname)
    return if not @bsmp_players.key?(player_id)
    @bsmp_players[player_id].nickname = nickname
    @bsmp_players[player_id].character_name = character_name
    @bsmp_players[player_id].character_index = character_index
  end

  def set_player_map(player_id, map_id)
    return if not @bsmp_players.key?(player_id)
    player = @bsmp_players[player_id]
    player.map_id = map_id

    SceneManager.scene.spriteset.update_player(player) if SceneManager.scene.class == Scene_Map and SceneManager.scene.spriteset
  end

  def set_player_speed(player_id, speed)
    return if not @bsmp_players.key?(player_id)
    @bsmp_players[player_id].move_speed = speed
  end
end

$bsmp_players = BSMPPlayers.new

# --- BSMP UI ---

class BSMP_Window < Window_Base
  Z       = 188
  MARGIN_X   = 16
  BACK_COLOR   = Color.new(0, 42, 102, 160)

  def initialize
    super(Graphics.width - window_width - MARGIN_X, 0, window_width, window_height)
    self.z = Z
    self.opacity = 0
    self.back_opacity = 0

    self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)
  end

  def window_height
    return line_height * 2
  end

  def window_width
    return Graphics.width / 2
  end

  def update

  end
end

class BSMPTimed_Window < BSMP_Window

  TIME_FRAMES = 180
  OPACITY   = 32

  def initialize
    super
    @frame_count = 0
  end

  def update
    super
    @frame_count += 1
    if @frame_count >= TIME_FRAMES
      self.contents_opacity -= OPACITY
      dispose if self.contents_opacity == 0
    end
  end

  def refresh(caption, text = "")

  end
end

class BSMPProgress_Window < BSMP_Window

  PROGRESS_HEIGHT = 5
  NOPROGRESS_COLOR = Color.new(200, 200, 200, 255)
  PROGRESS_COLOR = Color.new(136, 8, 8, 255)

  attr_reader :progress
  attr_reader :text

  def initialize
    super
    self.progress = 0.0
    @window_changed = false
  end

  def update
    super
    if @window_changed
      update_window_size
      update_progress
      @window_changed = false
    end
  end

  def window_height
    return line_height * 3 + 5 if @text
    return line_height * 2
  end

  def text=(text)
    @text = text
    @window_changed = true
  end

  def progress=(progress)
    @progress = progress
    @window_changed = true
  end

  def update_progress
    self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)

    off_y = line_height / 2
    if @text
      draw_text(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, line_height, @text)
      off_y += line_height + 5
    end
    @progress = [1.0, @progress].min
    self.contents.fill_rect(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, PROGRESS_HEIGHT, NOPROGRESS_COLOR)
    self.contents.fill_rect(MARGIN_X, off_y, self.contents.width * @progress - MARGIN_X * 2, PROGRESS_HEIGHT, PROGRESS_COLOR)
  end

  def update_window_size
    old_height = self.height
    self.height = window_height
    create_contents if old_height != self.height
  end

end

# --- BSMP HOOKS ---

class Spriteset_Map
  attr_reader :character_sprites
  attr_reader :bsmp_players

  alias bsmp_orig_initialize initialize
  alias bsmp_orig_create_characters create_characters
  alias bsmp_orig_update update

  def create_characters
    bsmp_orig_create_characters
    @bsmp_players = {}
    $bsmp_players.bsmp_players.each_value do |player|
      next if player.map_id != $game_map.map_id
      add_player(player)
    end
  end

  def update
    bsmp_orig_update
    @bsmp_players.each_value do |player|
      player.character.update
    end
  end

  def add_player(player)
    return if @bsmp_players.key?(player.player_id)
    sprite = Sprite_Character.new(@viewport1, player)
    @bsmp_players[player.player_id] = sprite
    @character_sprites.push(sprite)
  end

  def delete_player(player)
    return if not @bsmp_players.key?(player.player_id)
    sprite = @bsmp_players.delete(player.player_id)
    @character_sprites.delete(sprite)
    sprite.dispose
  end

  def update_player(player)
    if player.map_id == $game_map.map_id and not @bsmp_players.key?(player.id)
      # joined map
      add_player(player)
    elsif @bsmp_players.key?(player.player_id)
      # leaved from map
      delete_player(player)
    end
  end
end

class Sprite_Character

  attr_reader :nickname_sprite

  alias bsmp_orig_initialize initialize
  alias bsmp_orig_update update
  alias bsmp_orig_dispose dispose
  alias bsmp_orig_update_position update_position

  def initialize(viewport, character)
    bsmp_orig_initialize(viewport, character)
    @character_nickname = nil
  end

  def dispose
    bsmp_orig_dispose
    @nickname_sprite.dispose if @nickname_sprite
  end

  def nickname_width
    return 64
  end

  def nickname_height
    return 20
  end

  def create_nickname_sprite
    @nickname_sprite = Sprite_Base.new(self.viewport)
    @nickname_sprite.bitmap = Bitmap.new(nickname_width, nickname_height)
    @nickname_sprite.bitmap.font.size = 21
    @nickname_sprite.x = self.x - nickname_width / 2
    @nickname_sprite.y = self.y - 32 - nickname_height
    @nickname_sprite.z = 100
  end

  def nickname_changed?
    return @character_nickname != @character.nickname
  end

  def update
    bsmp_orig_update
    update_nickname if nickname_changed?
  end

  def update_nickname
    @character_nickname = @character.nickname

    create_nickname_sprite if not @nickname_sprite
    @nickname_sprite.bitmap.fill_rect(0, 0, @nickname_sprite.bitmap.width, @nickname_sprite.bitmap.height, Color.new(0, 0, 0, 0))

    off_x = [0, @nickname_sprite.bitmap.width - @nickname_sprite.bitmap.text_size(@character_nickname).width].max / 2
    @nickname_sprite.bitmap.draw_text(off_x, 0, @nickname_sprite.bitmap.width, @nickname_sprite.bitmap.height, @character_nickname)
  end

  def update_position
    bsmp_orig_update_position
    if @nickname_sprite
      @nickname_sprite.x = self.x - nickname_width / 2
      @nickname_sprite.y = self.y - 32 - nickname_height
    end
  end

  def character_pos_changed?
    @old_x != self.x or @old_y != self.y
  end

  def update_nickname_pos
    @nickname_sprite.x = self.x - nickname_width / 2
    @nickname_sprite.y = self.y - 32 - nickname_height
  end

end

class Game_Player

  alias bsmp_orig_update update
  alias bsmp_orig_refresh refresh
  alias bsmp_orig_move_straight move_straight
  alias bsmp_orig_move_diagonal move_diagonal

  attr_accessor :last_real_move_speed

  def update
    last_moving = moving?
    bsmp_orig_update
    send_pos_packet if last_moving and not moving?
    if @last_real_move_speed != real_move_speed
      @last_real_move_speed = real_move_speed
      send_speed_packet
    end
  end

  def refresh
    bsmp_orig_refresh

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_CHANGED_CHARACTER, 0, "#{@character_name};#{@character_index};#{self.actor.name}")
    bsmp_send_packet(packet)
  end

  def move_straight(d, turn_ok = true)
    bsmp_orig_move_straight(d, turn_ok) if not $disable_player_move

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_MOVED, 0, d.to_s)
    bsmp_send_packet(packet)
  end

  def move_diagonal(horz, vert)
    bsmp_orig_move_diagonal(horz, vert)

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_MOVED_DIAG, 0, "#{horz};#{vert}")
    bsmp_send_packet(packet)
  end

  def send_pos_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_CHANGED_POS, 0, "#{self.x};#{self.y}")
    bsmp_send_packet(packet)
  end

  def send_speed_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMPEvents::PLAYER_CHANGED_SPEED, 0, self.real_move_speed.to_s)
    bsmp_send_packet(packet)
  end

  def bsmp_enable_nickname
    @nickname = $game_party.battle_members[0].name
  end

end

class Game_Character

  attr_accessor :nickname

end

class Scene_Map

  attr_reader :spriteset

end

class Scene_Base

  alias bsmp_orig_update update
  def update
    bsmp_orig_update
    SteamUserStatsLite.instance.update
    bsmp_read_packets
  end

end

class Game_Map

  alias bsmp_orig_setup setup

  def setup(map_id)
    bsmp_orig_setup(map_id)
    return if not bsmp_network_running?
    bsmp_send_packet(BasicNetworkPacket.new(BSMPEvents::PLAYER_CHANGED_MAP, 0, map_id.to_s))
  end

end

# --- BSMP DEBUG ---

$bsmp_client = BSMPClient.new()
$bsmp_server = BSMPServer.new()

def bsmp_send_packet(packet)
  $bsmp_client.send_packet(packet) if $bsmp_client.connected?
  $bsmp_server.send_packet(packet) if $bsmp_server.running?
end

def bsmp_network_running?
  $bsmp_server.running? or $bsmp_client.connected?
end

def bsmp_read_packets
  $bsmp_server.read_packets if $bsmp_server.running?
  $bsmp_client.read_packets if $bsmp_client.connected?
end

def set_nick(nick)
  SceneManager.scene.spriteset.character_sprites[-1].set_nickname(nick)
end

def mech
  return SceneManager.scene.spriteset.character_sprites[-1]
end

def make_server(type = BSMPConfig::LOBBY_ONLY_FRIENDS, max_players = 10)
  # $bsmp_server = BSMPServer.new
  $bsmp_client.leave_lobby if $bsmp_client.connected?
  $bsmp_server.create_lobby(type, max_players)
end

def make_test_client
  # $bsmp_client = BSMPClient.new
  return if not $bsmp_server.running?
  $bsmp_client.read_channel_id = 1
  $bsmp_client.join_lobby($bsmp_server.lobby_id)
end

def make_test_player
  return if not $bsmp_server.running?
  player_id = $bsmp_server.get_lobby_owner
  # $bsmp_players.add(player_id, "TP1")
  # $bsmp_server.clients.push(BSMPServerClient.new(player_id, 1))

  # p "character sprite: #{$game_player.character_name}"
  # $bsmp_client.update_player_data

  client = BSMPServerClient.new(player_id, 1)
  $bsmp_server.add_client(client)
  $bsmp_client.update_player_data
end

def delete_test_player
  return if not $bsmp_server.running?
  player_id = $bsmp_server.get_lobby_owner

  client = $bsmp_server.find_client(player_id)
  $bsmp_server.delete_client(client) if client
end

def send_c2s_packet(type, data)
  return if not $bsmp_client.connected?
  packet = BasicNetworkPacket.new(type, 0, data)
  $bsmp_client.send_packet(packet)
end

def read_s2c_packets
  return if not $bsmp_server.running?
  $bsmp_server.read_packets
end

def set_skin(actor_id)
  actor = $data_actors[actor_id]
  return "Actor not found" if not actor
  $game_player.actor.set_graphic(actor.character_name, actor.character_index, actor.face_name, actor.face_index)
  $game_player.refresh
end

def show_test_window
  $bwnd = BSMPProgress_Window.new()
  $bwnd.text = MLLocalizedStrings["BSMP_SAVE_TRANSFER"]
  $bwnd.progress = 0.3
  $game_temp.streffect.push($bwnd)
  # window.draw_text(0, 0, window.window_width, window.line_height, "Test")
end

MLLocalizedStrings.add_required("bsmp")

# --- BSMP END ---
end # if Object.const_defined?(:SteamUserStatsLite) and Object.const_defined?(:SteamAPI)

end # not $imported["IDL-BSMP"]