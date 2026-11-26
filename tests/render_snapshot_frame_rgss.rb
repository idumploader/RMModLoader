module RenderSnapshotFrame
  def self.run(scene)
    ModLoader.parallel_renderer_validation(true)
    probe=ModLoader::ParallelRenderer
    w,h=Graphics.width,Graphics.height
    blank,expected,actual=Array.new(3){Bitmap.new(w,h)}
    begin
      probe.optimization(2)
      probe.reference_frame(expected)
      probe.capture_frame
      puts "FRAME capture #{probe.status}"
      probe.draw(actual)
      RenderSnapshotTilemap.equal!(actual,expected,'complete Screen snapshot')
      raise 'Empty Screen reference' if ModLoader.parallel_renderer_pixels_equal(expected,blank)
      ModLoader.dump_as_bmp(actual,'map080-frame.bmp')
      probe.submit_frame(blank,40)
      15.times { scene.update }
      probe.collect(actual)
      RenderSnapshotTilemap.equal!(actual,expected,'complete Screen frozen during scene update')
      puts "FRAME PASS #{w}x#{h} #{probe.status}"
      mode=File.exist?('frame-mode') ? File.read('frame-mode').to_i : 0
      raise probe.status unless ModLoader.parallel_renderer_frame_mode(mode)
      30.times { scene.update }
      state=ModLoader.parallel_renderer_frame_status
      raise state unless state.include?('"error":""')
      raise "Missing automatic pixel checks: #{state}" if mode>=2 && !state.include?('"checks":6')
      puts "FRAME_LOOP_BEGIN mode=#{mode} #{state}"
      2.times do |trial|
        ModLoader.map_frame_probe_start
        started=Time.now
        240.times do
          scene.update
          raise 'Scene/map changed during frame benchmark' unless SceneManager.scene.equal?(scene) && $game_map.map_id==80
        end
        wall=(Time.now-started)*1000
        puts "FRAME_LOOP mode=#{mode} size=#{w}x#{h} trial=#{trial} wall_ms=#{wall} #{ModLoader.map_frame_probe_stop}"
        state=ModLoader.parallel_renderer_frame_status
        puts "FRAME_LOOP_STATUS trial=#{trial} #{state}"
        raise state unless state.include?('"error":""')
      end
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      probe.clear
      [blank,expected,actual].each { |b| b.dispose }
    end
  end
end
