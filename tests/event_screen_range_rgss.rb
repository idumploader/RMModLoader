module EventScreenRangeTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.run
    data = RPG::Event.new(0, 0)
    data.id = 9999
    data.pages[0].move_type = 3
    data.pages[0].move_frequency = 5
    route = RPG::MoveRoute.new
    route.repeat = true
    route.list = [RPG::MoveCommand.new(20), RPG::MoveCommand.new(15, [1]), RPG::MoveCommand.new(0)]
    data.pages[0].move_route = route
    event = Game_Event.new($game_map.map_id, data)
    # Place both copies in visible map coordinates, independently of the player.
    display_x, display_y = $game_map.display_x, $game_map.display_y
    [4, 16].each do |screen_tile_x|
      event.instance_variable_set(:@real_x, display_x + screen_tile_x)
      event.instance_variable_set(:@real_y, display_y + 7)
      event.instance_variable_set(:@x, (display_x + screen_tile_x).to_i)
      event.instance_variable_set(:@y, (display_y + 7).to_i)
      old = event.hrfix_orig_near_the_screen?(11, 8)
      Map080Benchmark.log("RANGE tile_x=#{screen_tile_x} original=#{old} fixed=#{event.near_the_screen?}")
      check(event.near_the_screen?, "visible tile#{screen_tile_x} in range")
      directions = []
      24.times do
        event.instance_variable_set(:@stop_count, 100)
        event.update_self_movement
        directions << event.direction
      end
      check(directions.uniq.size > 1, "autonomous star rotation tile#{screen_tile_x}")
    end
    event.instance_variable_set(:@real_x, display_x - 20)
    check(!event.near_the_screen?, 'outside map view remains out of range')
  end
end
