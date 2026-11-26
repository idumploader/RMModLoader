module BSResolutionWeatherTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.run(scene)
    [80, 93].each do |map_id|
      if $game_map.map_id != map_id
        scene.terminate unless scene.instance_variable_get(:@bsresolution_terminated)
        scene.instance_variable_set(:@bsresolution_terminated, true)
        $game_map.setup(map_id)
        $game_player.moveto($game_map.width / 2, $game_map.height / 2)
        $game_player.center($game_player.x, $game_player.y)
        SceneManager.goto(Scene_Map)
        scene = SceneManager.scene
        scene.start
      end
      spriteset = scene.instance_variable_get(:@spriteset)
      weather = spriteset.instance_variable_get(:@weather)
      viewport = spriteset.instance_variable_get(:@viewport1)
      original_count = weather.instance_variable_get(:@sprites).size
      weather.type = 1
      weather.power = 9
      weather.ox = $game_map.display_x * 32
      weather.oy = $game_map.display_y * 32
      120.times { weather.update }
      particles = weather.instance_variable_get(:@sprites)
      check(particles.size == original_count, "map#{map_id} original particle count")
      check(particles.all? { |sprite| sprite.viewport.equal?(viewport) }, "map#{map_id} weather uses scaled map viewport")
      check(particles.all? { |sprite| sprite.z == 0x8000 }, "map#{map_id} rain above characters")
      points = [[80,60], [480,60], [80,360], [480,360]]
      visibility = particles.map { |sprite| sprite.visible }
      particles.each { |sprite| sprite.visible = false }
      3.times { Graphics.update }
      before = Graphics.snap_to_bitmap
      points.each_with_index do |point, index|
        sprite = particles[index]
        sprite.x = point[0] + weather.ox
        sprite.y = point[1] + weather.oy
        sprite.ox = weather.ox
        sprite.oy = weather.oy
        sprite.bitmap = weather.instance_variable_get(:@rain_bitmap)
        sprite.opacity = 255
        sprite.visible = true
      end
      3.times { Graphics.update }
      after = Graphics.snap_to_bitmap
      points.each_with_index do |point, index|
        x1 = (point[0] * Graphics.width / 640.0).floor
        x2 = ((point[0] + 8) * Graphics.width / 640.0).ceil
        y1 = (point[1] * Graphics.height / 480.0).floor
        y2 = ((point[1] + 43) * Graphics.height / 480.0).ceil
        changed = (y1...y2).any? do |y|
          (x1...x2).any? do |x|
            a = before.get_pixel(x,y); b = after.get_pixel(x,y)
            [a.red,a.green,a.blue,a.alpha] != [b.red,b.green,b.blue,b.alpha]
          end
        end
        check(changed, "map#{map_id} visible rain quadrant#{index}")
      end
      before.dispose; after.dispose
      particles.each_with_index { |sprite, index| sprite.visible = visibility[index] }
      15.times { weather.update }
      3.times { Graphics.update }
      shot = Graphics.snap_to_bitmap
      ModLoader.dump_as_bmp(shot, "resolution-weather-#{map_id}.bmp")
      shot.dispose
      scene.terminate
      scene.instance_variable_set(:@bsresolution_terminated, true)
    end
    Map080Benchmark.log('BSResolutionWeatherTest PASS')
  end
end
