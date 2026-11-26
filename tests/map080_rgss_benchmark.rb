# Installed only in the isolated Map080 stage, after the actual game scripts.
module Input
  class << self
    def press?(*args); false; end
    def trigger?(*args); false; end
    def repeat?(*args); false; end
    def dir4; 0; end
    def dir8; 0; end
  end
end
module Map080Benchmark
  def self.log(value)
    File.open('map080.log', 'ab') { |f| f.write(value.to_s + "\n"); f.flush }
  end
  def self.run
    scene = nil
    begin
      log "BOOT RGSS=#{RUBY_VERSION} size=#{Graphics.width}x#{Graphics.height}"
      srand(80080)
      DataManager.init
      DataManager.setup_new_game
      log "STATE fresh new game; map=#{$game_map.map_id} player=#{$game_player.x},#{$game_player.y}"
      $game_player.reserve_transfer(80, 10, 10, 2)
      $game_player.perform_transfer
      # Choose a walkable point near the centre, avoiding event tiles.
      chosen = nil
      positions = []
      $game_map.height.times do |y|
        $game_map.width.times do |x|
          positions << [x, y] if $game_map.events_xy(x, y).empty? && [2,4,6,8].any? { |d| $game_map.passable?(x, y, d) }
        end
      end
      chosen = positions.min_by { |x,y| (x-$game_map.width/2).abs + (y-$game_map.height/2).abs }
      raise 'No walkable point on Map080' unless chosen
      $game_player.moveto(*chosen)
      $game_player.refresh
      log "MAP id=#{$game_map.map_id} size=#{$game_map.width}x#{$game_map.height} events=#{$game_map.events.size} position=#{chosen.inspect}"
      SceneManager.goto(Scene_Map)
      scene = SceneManager.scene
      scene.start
      scene.post_start
      120.times do
        scene.update
        raise 'Scene/map changed during warmup' unless SceneManager.scene.equal?(scene) && $game_map.map_id == 80
      end
      Graphics.brightness = 255
      spriteset = scene.instance_variable_get(:@spriteset)
      characters = spriteset.instance_variable_get(:@character_sprites)
      tilemap = spriteset.instance_variable_get(:@tilemap)
      viewport = spriteset.instance_variable_get(:@viewport1)
      log "SCENE characters=#{characters ? characters.size : 'unknown'} tilemap=#{tilemap.class} viewport=#{viewport.rect.inspect} frame_rate=#{Graphics.frame_rate} map_original=#{ModLoader.config_get('hrfix_map_original_size')}"
      log "EVENTS interactions=#{ModLoader::EventInteractionToggle.enabled?} movement=#{ModLoader::MobMovementToggle.enabled?}" if defined?(ModLoader::EventInteractionToggle)
      shot = Graphics.snap_to_bitmap
      if ModLoader.respond_to?(:dump_as_bmp)
        ModLoader.dump_as_bmp(shot, 'map080.bmp')
      end
      shot.dispose
      if File.exist?('frame-snapshot-test')
        eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/render_snapshot_tilemap_rgss.rb'))
        eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/render_snapshot_frame_rgss.rb'))
        RenderSnapshotFrame.run(scene)
        File.open('map080.result','wb') { |f| f.write('PASS') }
        return
      end
      if File.exist?('plane-snapshot-test')
        eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/render_snapshot_tilemap_rgss.rb'))
        eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/render_snapshot_plane_rgss.rb'))
        RenderSnapshotPlane.check_map(scene)
        File.open('map080.result','wb') { |f| f.write('PASS') }
        return
      end
      if File.exist?('tilemap-snapshot-test')
        eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/render_snapshot_tilemap_rgss.rb'))
        RenderSnapshotTilemap.check_map(scene)
        File.open('map080.result','wb') { |f| f.write('PASS') }
        return
      end
      2.times do |trial|
        ModLoader.map_frame_probe_start
        started = Time.now
        240.times do
          scene.update
          raise 'Scene/map changed during measurement' unless SceneManager.scene.equal?(scene) && $game_map.map_id == 80
        end
        wall_ms = (Time.now-started)*1000.0
        stats = ModLoader.map_frame_probe_stop
        log "MAP_BENCH trial=#{trial} wall_ms=#{wall_ms} scene=Scene_Map map=80 size=#{Graphics.width}x#{Graphics.height} #{stats}"
      end
      log "FINAL map=#{$game_map.map_id} pos=#{$game_player.x},#{$game_player.y} events=#{$game_map.events.size}"
      File.open('map080.result','wb') { |f| f.write('PASS') }
    rescue Exception => error
      ModLoader.map_frame_probe_stop if ModLoader.respond_to?(:map_frame_probe_stop)
      log "#{error.class}: #{error.message}"
      error.backtrace.each { |line| log line }
      File.open('map080.result','wb') { |f| f.write('FAIL') }
    ensure
      SceneManager.exit
      scene.terminate if scene
    end
  end
end
module SceneManager
  def self.run
    Map080Benchmark.run
  end
end
