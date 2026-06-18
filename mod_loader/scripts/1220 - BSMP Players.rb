#==============================================================================
# BSMP Players — part 3/5: remote-player model. Player_Character (a Game_Character
# driven by network packets) and Players (the id => character registry that the
# event handlers and spriteset hooks operate on). See 1200 - BSMP Core.rb.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Players"]
$imported["IDL-BSMP-Players"] = "1.0"

if defined?(BSMP)

module BSMP

  class Player_Character < Game_Character

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

  class Players

    attr_accessor :bsmp_players

    def initialize
      @bsmp_players ||= {}
    end

    def add(player_id, nickname)
      return if @bsmp_players.key?(player_id)
      new_character = Player_Character.new(player_id, "", nickname)
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

end # module BSMP

$bsmp_players = BSMP::Players.new

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Players"]
