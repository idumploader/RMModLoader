# Load inside RGSS with a running map scene; tests real allocation/fallback paths.
module ParallelRendererResources
  def self.run(scene)
    display = ModLoader::Display
    large = sprite = nil
    saved_limit = display.memory_limit_mib
    saved_notices = display.renderer_notices?
    begin
      display.parallel_rendering = false
      ModLoader.parallel_renderer_validation(false)
      display.renderer_notices = true
      [false, true].each do |wait|
        display.wait_for_frame = wait
        display.memory_limit_mib = 256
        display.parallel_rendering = true
        20.times { scene.update }
        report = ModLoader.parallel_renderer_frame_status
        raise report unless report.include?('"checks":0') && report.include?('"error":""')
        raise 'Unexpected health warning' unless ModLoader.parallel_renderer_health == 0
        # This Bitmap alone exceeds the 32 MiB budget, irrespective of map assets.
        large = Bitmap.new(3072, 3072)
        sprite = Sprite.new
        sprite.bitmap = large
        display.memory_limit_mib = 32
        70.times { scene.update }
        report = ModLoader.parallel_renderer_frame_status
        raise report unless report.include?('"capacity_fallback":true')
        raise report unless report[/"fallback_frames":(\d+)/, 1].to_i >= 60
        raise report unless report[/"memory_peak_bytes":(\d+)/, 1].to_i <= 256*1024*1024
        raise report unless report[/"memory_bytes":(\d+)/, 1].to_i <= 32*1024*1024
        raise 'Missing memory health warning' unless ModLoader.parallel_renderer_health == 3
        notice = ModLoader::RendererNotice.instance_variable_get(:@sprite)
        raise 'Missing screen warning' unless notice && !notice.disposed?
        puts "CAPACITY wait=#{wait} #{report}"
        sprite.dispose; sprite = nil
        large.dispose; large = nil
        display.memory_limit_mib = 256
        70.times { scene.update }
        report = ModLoader.parallel_renderer_frame_status
        raise report unless report.include?('"error":""') && report.include?('"checks":0')
        raise 'Warning did not clear' unless ModLoader.parallel_renderer_health == 0 &&
          ModLoader::RendererNotice.instance_variable_get(:@sprite).nil?
        puts "RECOVERED wait=#{wait} #{report}"
        display.parallel_rendering = false
        report = ModLoader.parallel_renderer_status
        raise report unless report.include?('"memory_bytes":0') && report.include?('"worker_running":false')
        puts "OFF wait=#{wait} #{report}"
      end
      true
    ensure
      sprite.dispose if sprite
      large.dispose if large
      display.parallel_rendering = false
      display.renderer_notices = saved_notices
      display.memory_limit_mib = saved_limit
    end
  end
end
