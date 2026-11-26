module MapFrameTraceTest
  def self.run(scene)
    [0, 3].each do |mode|
      raise 'mode failed' unless ModLoader.parallel_renderer_frame_mode(mode)
      ModLoader.map_frame_trace_start
      120.times do
        scene.update
        raise 'scene changed' unless SceneManager.scene.equal?(scene) && $game_map.map_id == 80
      end
      File.open("map-frame-trace-#{mode}.json", 'wb') do |file|
        file.write(ModLoader.map_frame_trace_stop)
      end
      puts "FRAME_TRACE mode=#{mode} status=#{ModLoader.map_frame_trace_status}"
    end
  ensure
    ModLoader.map_frame_trace_stop if ModLoader.respond_to?(:map_frame_trace_stop)
    ModLoader.parallel_renderer_frame_mode(0)
  end
end
