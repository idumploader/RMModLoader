#==============================================================================
# BSMP Hooks — part 5/5 (loads last): patches into the game's own classes
# (Spriteset_Map / Sprite_Character / Game_Player / Game_Map / Scene_*), the
# $bsmp_client / $bsmp_server / $bsmp_players wiring and the debug console
# commands. These reopen top-level RPG Maker classes, so they live outside
# module BSMP. See 1200 - BSMP Core.rb.
#
# Console commands:
#   make_server(type, max_players)   make_test_client    make_test_player
#   delete_test_player               send_c2s_packet(type, data)
#   read_s2c_packets                 set_skin(actor_id)  set_nick(nick)
#   show_test_window                 mech
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Hooks"]
$imported["IDL-BSMP-Hooks"] = "1.0"

if defined?(BSMP)

class Spriteset_Map
  attr_reader :character_sprites
  attr_reader :bsmp_players

  alias bsmp_orig_initialize initialize
  alias bsmp_orig_create_characters create_characters
  alias bsmp_orig_update update
  alias bsmp_orig_dispose dispose

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
    # Advance the remote players' Game_Character logic (movement interpolation):
    # @bsmp_players here holds sprites, which bsmp_orig_update already updates.
    $bsmp_players.bsmp_players.each_value do |character|
      character.update if character.map_id == $game_map.map_id
    end
    update_bsmp_status
  end

  def dispose
    dispose_bsmp_windows
    bsmp_orig_dispose
  end

  # Show the status panel while networking runs; create it lazily (so toggling the
  # server on/off mid-map works) and drop everything the moment networking stops.
  def update_bsmp_status
    if bsmp_network_running?
      @bsmp_status_window ||= BSMP::Status_Window.new
      @bsmp_status_window.update
      update_bsmp_roster
    else
      dispose_bsmp_windows
    end
  end

  # Full roster overlay while the roster key is held (scoreboard-style).
  def update_bsmp_roster
    if ModLoader.respond_to?(:input_press?) and ModLoader.input_press?(BSMP::Config::ROSTER_KEY)
      @bsmp_roster_window ||= BSMP::Roster_Window.new
      @bsmp_roster_window.update
    elsif @bsmp_roster_window
      @bsmp_roster_window.dispose
      @bsmp_roster_window = nil
    end
  end

  def dispose_bsmp_windows
    if @bsmp_status_window
      @bsmp_status_window.dispose
      @bsmp_status_window = nil
    end
    if @bsmp_roster_window
      @bsmp_roster_window.dispose
      @bsmp_roster_window = nil
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
    on_map = player.map_id == $game_map.map_id
    shown = @bsmp_players.key?(player.player_id)
    if on_map and not shown
      # joined our map
      add_player(player)
    elsif shown and not on_map
      # left our map
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
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_CHARACTER, 0, "#{@character_name};#{@character_index};#{self.actor.name}")
    bsmp_send_packet(packet)
  end

  def move_straight(d, turn_ok = true)
    bsmp_orig_move_straight(d, turn_ok) if not $disable_player_move

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_MOVED, 0, d.to_s)
    bsmp_send_packet(packet)
  end

  def move_diagonal(horz, vert)
    bsmp_orig_move_diagonal(horz, vert)

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_MOVED_DIAG, 0, "#{horz};#{vert}")
    bsmp_send_packet(packet)
  end

  def send_pos_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_POS, 0, "#{self.x};#{self.y}")
    bsmp_send_packet(packet)
  end

  def send_speed_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_SPEED, 0, self.real_move_speed.to_s)
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
    SteamAPI.run_callbacks
    bsmp_read_packets
  end

end

class Game_Map

  alias bsmp_orig_setup setup

  def setup(map_id)
    bsmp_orig_setup(map_id)
    return if not bsmp_network_running?
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_MAP, 0, map_id.to_s))
  end

end

# --- BSMP globals + debug console commands ---

$bsmp_client = BSMP::Client.new()
$bsmp_server = BSMP::Server.new()

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
  $game_player.nickname = nick
end

def mech
  return SceneManager.scene.spriteset.character_sprites[-1]
end

def make_server(type = BSMP::Config::LOBBY_ONLY_FRIENDS, max_players = 10)
  # $bsmp_server = BSMP::Server.new
  $bsmp_client.leave_lobby if $bsmp_client.connected?
  $bsmp_server.create_lobby(type, max_players)
end

def make_test_client
  # $bsmp_client = BSMP::Client.new
  return if not $bsmp_server.running?
  $bsmp_client.read_channel_id = 1
  $bsmp_client.join_lobby($bsmp_server.lobby_id)
end

def make_test_player
  return if not $bsmp_server.running?
  player_id = $bsmp_server.get_lobby_owner

  client = BSMP::ServerClient.new(player_id, 1)
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
  $bwnd = BSMP::Progress_Window.new()
  $bwnd.text = MLLocalizedStrings["BSMP_SAVE_TRANSFER"]
  $bwnd.progress = 0.3
  $game_temp.streffect.push($bwnd)
end

MLLocalizedStrings.add_required("bsmp")

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Hooks"]
