module RenderSnapshotFrameContract
  def self.run(scene, mode = 2)
    ModLoader.parallel_renderer_validation(true)
    probe = ModLoader::ParallelRenderer
    sprite = bitmap = viewport = nil
    begin
      probe.optimization(2)
      raise probe.status unless ModLoader.parallel_renderer_frame_mode(mode)
      20.times { scene.update }
      state = ModLoader.parallel_renderer_frame_status
      raise state unless state.include?('"checks":6') && state.include?("\"mode\":#{mode}")
      begin
        probe.capture_frame
        raise 'Manual capture unexpectedly accepted'
      rescue RuntimeError => error
        raise unless error.message.include?('Disable automatic frame mode')
      end
      raise 'Guard disabled pipeline' unless ModLoader.parallel_renderer_frame_status.include?("\"mode\":#{mode}")
      puts "FRAME_CONTRACT manual guard PASS #{state}"
      raise probe.status unless ModLoader.parallel_renderer_frame_mode(0)
      probe.capture_frame
      probe.clear
      puts 'FRAME_CONTRACT drain and manual capture PASS'
      raise probe.status unless ModLoader.parallel_renderer_frame_mode(mode)
      10.times { scene.update }
      bitmap = Bitmap.new(32,32)
      bitmap.fill_rect(0,0,32,32,Color.new(255,0,0,255))
      viewport = Viewport.new(0,0,200,200)
      viewport.zoom = 1.5
      sprite = Sprite.new(viewport)
      sprite.bitmap = bitmap
      sprite.x = sprite.y = 100
      sprite.angle = 15
      10.times { scene.update }
      state = ModLoader.parallel_renderer_frame_status
      expected_mode=mode
      raise state unless state.include?("\"mode\":#{expected_mode}") && state.include?('Custom ViewportEffects')
      10.times { scene.update }
      puts "FRAME_CONTRACT fallback and continuing scene PASS #{state}"
      if [2,3].include?(mode)
        raise state unless state.include?('"fallback":true')
        viewport.zoom=1.0
        20.times { scene.update }
        state=ModLoader.parallel_renderer_frame_status
        raise state unless state.include?("\"mode\":#{mode}") && state.include?('"fallback":false') && state.include?('"error":""')
        puts "FRAME_CONTRACT automatic resume after effect PASS #{state}"
      end
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      sprite.dispose if sprite
      viewport.dispose if viewport
      bitmap.dispose if bitmap
      probe.clear
    end
  end
end
