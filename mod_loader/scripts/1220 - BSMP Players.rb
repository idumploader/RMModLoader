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
    attr_accessor :location_name
    attr_accessor :ping

    def initialize(player_id, sprite_name, nickname)
      super()
      @player_id = player_id
      @character_name = sprite_name
      @character_index = 0
      @nickname = nickname
      @map_id = 0
      @location_name = ""
      @ping = -1
    end

    def refresh
      super
    end

    def move_to_real(x, y)
      @real_x = x
      @real_y = y
    end

    # Tiles between the interpolated (@real) position and an authoritative one
    # before we hard-snap instead of gliding: small corrections glide, big jumps
    # (teleport / map change / initial spawn) cut.
    SNAP_DISTANCE = 3

    # Advance the authoritative target one tile in d and face that way, leaving
    # @real_x/@real_y for update_move to glide toward. Unlike Game_Character's
    # move_straight this does NOT reset @real to "one tile behind", so overlapping
    # packets accumulate into continuous motion instead of stalling/jerking.
    # Passability is re-checked locally (same map as sender) so blocked moves the
    # sender still broadcasts don't march the ghost through walls.
    def network_move(d)
      return if d == 0
      set_direction(d)
      return unless passable?(@x, @y, d)
      @x = $game_map.round_x_with_direction(@x, d)
      @y = $game_map.round_y_with_direction(@y, d)
    end

    def network_move_diagonal(horz, vert)
      if diagonal_passable?(@x, @y, horz, vert)
        @x = $game_map.round_x_with_direction(@x, horz)
        @y = $game_map.round_y_with_direction(@y, vert)
      end
      set_direction(horz) if @direction == reverse_dir(horz)
      set_direction(vert) if @direction == reverse_dir(vert)
    end

    # Authoritative position: glide for small corrections (the common case, e.g.
    # the on-stop anchor), hard-snap for big jumps.
    def network_moveto(x, y)
      # No loaded map yet (a peer's position arrived while we're on the title /
      # loading): store it directly. moveto does `x % $game_map.width`, and at the
      # title $game_map.@map is nil -> width crashes. We re-snap once on the map.
      if not $game_map or $game_map.map_id == 0
        @x = x; @y = y; @real_x = x; @real_y = y
        return
      end
      if (x - @real_x).abs + (y - @real_y).abs > SNAP_DISTANCE
        moveto(x, y)
      else
        @x = x
        @y = y
      end
    end

    # How much faster than the base glide we may go to catch up when the target
    # has pulled ahead (capped so a big gap eases in rather than teleporting).
    CATCHUP_MAX = 4.0
    # Per-frame easing of the glide multiplier toward its target (low-pass): the
    # gap is a sawtooth (each packet bumps it a tile, the glide eats it back), so
    # smoothing the multiplier instead of reacting to the raw gap removes the
    # straight-line micro-jitter and the spike on sharp turns.
    CATCHUP_SMOOTH = 0.2
    # Below this gap we don't catch up at all, so in-sync straight walking holds a
    # steady base speed instead of modulating around it.
    CATCHUP_DEADZONE = 1.25

    # Glide speed. Within the dead zone this is the normal move-speed glide
    # (linear, lands exactly). Further behind — e.g. the sender's dash outran our
    # last speed packet, or packets bunched after a network stall — we speed up
    # toward gap-proportional catch-up so continuous movement keeps the sender's
    # pace instead of trailing at a fixed (often half) speed. The gap uses
    # Chebyshev distance so a corner doesn't double-count vs a straight lag, and
    # the multiplier is low-passed so the speed changes smoothly. update_move
    # clamps to the target, so it never overshoots.
    def distance_per_frame
      base = super
      gap = [(@x - @real_x).abs, (@y - @real_y).abs].max
      target_mult = gap <= CATCHUP_DEADZONE ? 1.0 : [gap, CATCHUP_MAX].min
      @glide_mult ||= 1.0
      @glide_mult += (target_mult - @glide_mult) * CATCHUP_SMOOTH
      base * @glide_mult
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

    # Remove every remote player (and their sprites) — used when we leave a session.
    def clear
      scene = SceneManager.scene
      if scene.is_a?(Scene_Map) and scene.spriteset
        @bsmp_players.each_value { |character| scene.spriteset.delete_player(character) }
      end
      @bsmp_players.clear
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
      @bsmp_players[player_id].network_move(d)
    end

    def move_player_diagonal(player_id, horz, vert)
      return if not @bsmp_players.key?(player_id)
      @bsmp_players[player_id].network_move_diagonal(horz, vert)
    end

    def player_moveto(player_id, x, y)
      return if not @bsmp_players.key?(player_id)
      @bsmp_players[player_id].network_moveto(x, y)
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

    def set_player_location(player_id, location_name)
      return if not @bsmp_players.key?(player_id)
      @bsmp_players[player_id].location_name = location_name
    end

    def set_player_ping(player_id, ping)
      return if not @bsmp_players.key?(player_id)
      @bsmp_players[player_id].ping = ping
    end

  end

end # module BSMP

$bsmp_players = BSMP::Players.new

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Players"]
