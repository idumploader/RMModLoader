module RenderSnapshotReset
  def self.run
    ModLoader.parallel_renderer_validation(true)
    probe=ModLoader::ParallelRenderer
    $snapshot_reset_runs=($snapshot_reset_runs || 0)+1
    puts "RESET iteration=#{$snapshot_reset_runs} #{probe.status}"
    if $snapshot_reset_runs>1
      state=probe.status
      raise state unless state.include?('"queue_depth":0') && state.include?('"captured":false')
      raise 'automatic mode survived reset' unless ModLoader.parallel_renderer_frame_status.include?('"mode":0')
    end
    vp=Viewport.new(0,0,160,120)
    sprite=Sprite.new(vp)
    bitmap=Bitmap.new(64,64)
    bitmap.fill_rect(bitmap.rect,Color.new(230,40,170,220))
    sprite.bitmap=bitmap; sprite.angle=33
    template=Bitmap.new(160,120)
    probe.optimization(2)
    Graphics.update
    if $snapshot_reset_runs==1
      probe.submit(vp,template,10000)
      puts 'RESET raising RGSSReset with worker pending'
      # Same exception handled by native rgss_main for F12. Do not rescue here.
      raise RGSSReset
    end
    ModLoader.parallel_renderer_frame_mode(3)
    30.times { Graphics.update }
    state=ModLoader.parallel_renderer_frame_status
    raise state unless state.include?('"checks":6') && state.include?('"mode":3') && state.include?('"error":""')
    puts "RESET recovered automatic rotation PASS #{state}"
    puts 'RESET normal exit with pending automatic frame'
    File.open('render-smoke.result','wb') { |f| f.write('PASS') }
  end
end
