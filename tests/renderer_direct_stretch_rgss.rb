eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/renderer_raster_workers_rgss.rb'))
module LocalMap108Compare
  class << self
    alias_method :raster_only_run, :run
    def run(scene)
      raise 'Direct output setter failed' unless ModLoader.parallel_renderer_set_direct_output(true)
      raise 'Parallel stretch setter failed' unless ModLoader.parallel_renderer_set_parallel_stretch(true)
      raster_only_run(scene)
      viewport=Viewport.new(7,11,Graphics.width-23,Graphics.height-29)
      bitmap=Bitmap.new(659,503)
      bitmap.fill_rect(bitmap.rect,Color.new(41,117,203,173))
      20.times {|i| bitmap.fill_rect(i*31,i*23,19,41,Color.new(i*11,255-i*9,13,51+i*9))}
      sprite=Sprite.new(viewport); sprite.bitmap=bitmap
      viewport.source_size(641,479)
      [2,3].each do |workers|
        ModLoader.parallel_renderer_set_workers(workers)
        check(scene,"workers=#{workers} fractional641x479 odd_viewport")
        state=ModLoader.parallel_renderer_frame_status
        # check switches mode OFF and resets counters after its validation.
        raise 'Renderer error '+state unless state.include?('"error":""')
      end
      sprite.dispose; sprite=nil;viewport.dispose;viewport=nil;bitmap.dispose;bitmap=nil
      raise 'Direct output counter unchanged' unless ModLoader.parallel_renderer_frame_status =~ /"direct_presentations":[1-9]/
      ModLoader.parallel_renderer_frame_mode(0)
      ModLoader.parallel_renderer_set_workers(3)
      [2,3].each do |mode|
        ModLoader.parallel_renderer_frame_mode(mode)
        60.times { scene.update }
        state=ModLoader.parallel_renderer_frame_status
        raise 'Direct mode failure '+state unless state.include?('"error":""')
        Map080Benchmark.log('DIRECT_MODE '+state)
        ModLoader.parallel_renderer_frame_mode(0)
      end
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      ModLoader.parallel_renderer_set_direct_output(false)
      sprite.dispose if sprite && !sprite.disposed?
      viewport.dispose if viewport && !viewport.disposed?
      bitmap.dispose if bitmap && !bitmap.disposed?
    end
  end
end
