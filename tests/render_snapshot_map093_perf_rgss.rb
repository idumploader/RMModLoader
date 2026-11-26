module RenderSnapshotMap093Perf
  def self.run(scene)
    ModLoader.parallel_renderer_validation(true)
    begin
      ModLoader.parallel_renderer_optimization(2)
      [0,3,0].each_with_index do |mode,trial|
        raise 'mode rejected' unless ModLoader.parallel_renderer_frame_mode(mode)
        30.times { scene.update }
        puts "PERF_BEGIN trial=#{trial} #{ModLoader.parallel_renderer_frame_status}"
        ModLoader.map_frame_probe_start
        started=Time.now
        240.times { scene.update }
        wall=(Time.now-started)*1000
        puts "PERF_RESULT trial=#{trial} mode=#{mode} size=#{Graphics.width}x#{Graphics.height} wall_ms=#{wall} #{ModLoader.map_frame_probe_stop}"
        state=ModLoader.parallel_renderer_frame_status
        puts "PERF_END trial=#{trial} #{state}"
        raise state unless state.include?('"error":""') && state.include?('"fallback":false')
        raise state if mode==3 && !state.include?('"checks":6')
        raise state unless state.include?("\"mode\":#{mode}")
      end
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
    end
  end
end
