# Run after a live resolution change. A white layer immediately below the
# engine's brightness sprite exposes uncovered pixels even on a dark map.
module HRFixBrightnessTest
  def self.run
    brightness = Graphics.brightness
    sprite = source = actual = expected = nil
    begin
      source = Bitmap.new(1, 1)
      source.fill_rect(source.rect, Color.new(255, 255, 255, 255))
      sprite = Sprite.new
      sprite.bitmap = source
      sprite.zoom_x = Graphics.width
      sprite.zoom_y = Graphics.height
      sprite.z = 2147483645
      results = []
      [0, 128, 255].each do |level|
        Graphics.brightness = level
        actual = Graphics.snap_to_bitmap
        color = actual.get_pixel(0, 0)
        raise "Wrong brightness #{level}: #{color}" unless
          [color.red, color.green, color.blue].all? { |v| (v - level).abs <= 1 }
        expected = Bitmap.new(Graphics.width, Graphics.height)
        expected.fill_rect(expected.rect, color)
        raise "Brightness #{level} does not cover the full screen" unless
          ModLoader.parallel_renderer_pixels_equal(actual, expected)
        results << [Graphics.width, Graphics.height, level, color.red]
        actual.dispose; actual = nil
        expected.dispose; expected = nil
      end
      results
    ensure
      Graphics.brightness = brightness
      sprite.dispose if sprite
      [source, actual, expected].compact.each { |bitmap| bitmap.dispose unless bitmap.disposed? }
    end
  end
end

module DisplayLiveResizeTest
  def self.run(scene)
    display = ModLoader::Display
    raise 'No live API' unless display.live_resize_available?
    ModLoader.parallel_renderer_set_memory_limit_mib(512)
    ModLoader.parallel_renderer_set_workers(3)
    ModLoader.parallel_renderer_set_parallel_stretch(true)
    objects = [$game_map, $game_player, $game_party, $game_system, $game_map.interpreter]
    position = [$game_player.x, $game_player.y]
    map_id = $game_map.map_id
    modes = [0, 2, 3, 3, 2]
    initial_map = display.map_size
    # Selecting the current settings is a no-op and must consume pending values.
    display.resolution = display.resolution
    display.map_size = display.map_size
    scene.update
    raise 'No-op recreated map' unless SceneManager.scene.equal?(scene)
    raise 'No-op retained pending settings' if display.instance_variable_get(:@live_resolution) || display.instance_variable_get(:@live_map_size)
    changes = ['1280x720', '1920x1080', '800x600', '2560x1440', '640x480'].map { |v| [v, initial_map] }
    # Same-resolution switches in both directions, with renderer OFF/wait/async.
    changes += [[:original,0],[:render,2],[:original,3],[:render,3],[:original,2],[:render,0]].map { |v,m| ['1280x720',v,m] }
    changes.each_with_index do |change, index|
      resolution, map_size, requested_mode = change
      requested_mode ||= modes[index % modes.size]
      ModLoader.parallel_renderer_optimization(2)
      ModLoader.parallel_renderer_frame_mode(requested_mode)
      12.times { scene.update }
      old_size = [Graphics.width, Graphics.height]
      old_tilemap = scene.instance_variable_get(:@spriteset).instance_variable_get(:@tilemap)
      item = ModLoader::ModMenu.items_for('Display').find { |entry| entry.label == 'Render resolution' }
      raise 'Disabled resolution menu' unless item.selectable?
      scene.modmenu_open_window
      item.value = resolution
      map_item = ModLoader::ModMenu.items_for('Display').find { |entry| entry.label == 'Map size' }
      raise 'Disabled map menu' unless map_item.selectable?
      before_map = ModLoader.hrfix_settings(false)[2]
      map_item.value = map_size
      raise 'Map applied before menu close' unless ModLoader.hrfix_settings(false)[2] == before_map
      raise 'Applied before menu close' unless [Graphics.width, Graphics.height] == old_size
      scene.update
      raise 'Recreated scene with menu open' unless SceneManager.scene.equal?(scene)
      scene.modmenu_dispose_window
      scene.update
      raise 'Did not request scene recreation' if SceneManager.scene.equal?(scene)
      state = ModLoader.parallel_renderer_frame_status
      raise 'Queue retained old resources '+state unless state.include?('"memory_bytes":0') && state.include?('"worker_running":false')
      scene.pre_terminate
      scene.terminate
      Map080Benchmark.log('LIVE_TERMINATED '+resolution)
      scene.instance_variable_set(:@live_test_terminated, true)
      scene = SceneManager.scene
      scene.start
      Map080Benchmark.log('LIVE_STARTED '+resolution)
      scene.post_start
      Map080Benchmark.log('LIVE_POST_STARTED '+resolution)
      raise 'Wrong new resolution' unless [Graphics.width, Graphics.height].join('x') == resolution
      Map080Benchmark.log('LIVE_BRIGHTNESS_PASS '+HRFixBrightnessTest.run.inspect)
      raise 'Renderer mode lost' unless ModLoader.parallel_renderer_current_mode == requested_mode
      raise 'Game objects changed' unless objects == [$game_map, $game_player, $game_party, $game_system, $game_map.interpreter]
      raise 'Player/map changed' unless position == [$game_player.x, $game_player.y] && $game_map.map_id == map_id
      raise 'Old tilemap alive' unless old_tilemap.disposed?
      raise 'Wrong map mode' unless ModLoader.hrfix_settings(false)[2] == (map_size == :original)
      logical = map_size == :original ? [640,480] : [Graphics.width,Graphics.height]
      raise 'Wrong logical camera' unless [$game_map.screen_tile_x,$game_map.screen_tile_y] == logical.map { |v| v / 32 }
      weather = scene.instance_variable_get(:@spriteset).instance_variable_get(:@weather)
      raise 'Weather mode stale' unless !!weather.hrfix_original_map_size == (map_size == :original)
      GraphicsReplace::RESIZE_MAPPING.each do |path, dimensions|
        next unless path.start_with?('Graphics/Parallaxes/')
        raise 'Parallax mapping stale' unless dimensions == logical
      end
      raise 'Map helper stale' unless HRFix::MapSize.original? == (map_size == :original)
      raise 'Settings not saved'  unless ModLoader.hrfix_settings(true) == ModLoader.hrfix_settings(false)
      ModLoader.parallel_renderer_frame_mode(0)
      ModLoader.parallel_renderer_validation(true)
      ModLoader.parallel_renderer_frame_mode(3)
      70.times { scene.update }
      status = ModLoader.parallel_renderer_frame_status
      raise 'Pixel check failed '+status unless status.include?('"checks":6') && status.include?('"error":""') && status.include?('"fallback":false')
      Map080Benchmark.log('LIVE_RESIZE_PASS '+resolution+' map='+map_size.to_s+' '+status)
      shot = Graphics.snap_to_bitmap
      ModLoader.dump_as_bmp(shot, "live-resize-#{resolution}.bmp")
      shot.dispose
      ModLoader.parallel_renderer_validation(false)
    end
    (0..4).each do |mode|
      raise 'Overlay option failed' unless display.send(:overlay_mode=, mode) && display.overlay_mode == mode
      ModLoader.steam_overlay_set_optimizations(0)
      display.restore_overlay
      raise 'Overlay preference lost' unless display.overlay_mode == mode
    end
    raise 'Invalid map flag accepted' if ModLoader.apply_hrfix_map_size(nil)
    raise 'Invalid map choice accepted' if display.send(:map_size=, :invalid)
    raise 'Invalid resize accepted' if ModLoader.apply_hrfix_resolution(1, 1)
    Map080Benchmark.log('LIVE_OVERLAY_PREFERENCES_PASS')
    ModLoader.parallel_renderer_frame_mode(0)
    scene.terminate
    scene.instance_variable_set(:@live_test_terminated, true)
    SceneManager.goto(Scene_Title)
    title = SceneManager.scene
    title.start
    title.post_start
    title.modmenu_open_window
    raise 'Title resize request failed' unless display.send(:resolution=, '1920x1080')
    title.update
    raise 'Title recreated before close' unless SceneManager.scene.equal?(title)
    title.modmenu_dispose_window
    title.update
    raise 'Title did not recreate' if SceneManager.scene.equal?(title)
    title.pre_terminate
    title.terminate
    title = SceneManager.scene
    title.start
    title.post_start
    20.times { title.update }
    raise 'Title resolution wrong' unless [Graphics.width, Graphics.height] == [1920,1080]
    Map080Benchmark.log('LIVE_TITLE_PASS')
    title.terminate
    # Cold title: Game_Player exists but Game_Map has never been set up.
    DataManager.create_game_objects
    raise 'Expected unloaded map' unless $game_map.map_id == 0
    SceneManager.goto(Scene_Title)
    title = SceneManager.scene
    title.start; title.post_start
    [[:original,'800x600'],[:render,'1280x720']].each do |map_size,resolution|
      title.modmenu_open_window
      raise 'Cold title resolution rejected' unless display.send(:resolution=, resolution)
      raise 'Cold title map size rejected' unless display.send(:map_size=, map_size)
      title.update
      raise 'Cold title recreated with menu open' unless SceneManager.scene.equal?(title)
      title.modmenu_dispose_window; title.update
      title.pre_terminate; title.terminate
      title = SceneManager.scene
      title.start; title.post_start
      20.times { title.update }
      raise 'Cold title resolution wrong' unless [Graphics.width,Graphics.height].join('x') == resolution
      raise 'Cold title map changed' unless $game_map.map_id == 0
      raise 'Cold title preference wrong' unless ModLoader.hrfix_settings(false)[2] == (map_size == :original)
      Map080Benchmark.log('LIVE_COLD_TITLE_PASS '+resolution+' '+map_size.to_s)
    end
    title.terminate
  end
end
