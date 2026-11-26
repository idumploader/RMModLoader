module LocalMap108Compare
  def self.check(scene,label)
    ModLoader.parallel_renderer_frame_mode(0)
    ModLoader.parallel_renderer_validation(true)
    ModLoader.parallel_renderer_frame_mode(3)
    36.times { scene.update }
    state=ModLoader.parallel_renderer_frame_status
    raise label+' '+state unless state.include?('"checks":6') && state.include?('"error":""') && state.include?('"fallback":false')
    Map080Benchmark.log('RASTER_VALIDATION '+label+' '+state)
    ModLoader.parallel_renderer_frame_mode(0)
  end
  def self.run(scene)
    bitmap=viewport=sprite=plane=nil
    ModLoader.parallel_renderer_set_memory_limit_mib(512)
    ModLoader.parallel_renderer_optimization(2)
    bitmap=Bitmap.new(Graphics.width+19,Graphics.height+13)
    bitmap.fill_rect(bitmap.rect,Color.new(10,40,150,173))
    24.times do |i|
      bitmap.fill_rect(i*83,i*47,123,153,Color.new(i*9,255-i*7,i*5,40+i*8))
    end
    viewport=Viewport.new(7,11,Graphics.width-23,Graphics.height-29)
    viewport.z=999
    sprite=Sprite.new(viewport)
    sprite.bitmap=bitmap
    sprite.x=-9; sprite.y=-17
    [1,2,3].each do |workers|
      raise 'Worker setter failed' unless ModLoader.parallel_renderer_set_workers(workers)
      [0,1,2].each do |blend|
        sprite.blend_type=blend; sprite.opacity=191
        sprite.tone=Tone.new(31,-19,47,blend==0 ? 83 : 0)
        sprite.color=Color.new(47,83,23,91)
        check(scene,"workers=#{workers} odd_clip blend=#{blend} tone")
      end
      sprite.tone=Tone.new; sprite.color=Color.new(0,0,0,0)
      sprite.opacity=255; sprite.blend_type=0
      sprite.mirror=true
      check(scene,"workers=#{workers} mirrored_serial")
      sprite.mirror=false; sprite.zoom_x=0.71; sprite.zoom_y=0.83
      check(scene,"workers=#{workers} scaled_serial")
      sprite.zoom_x=sprite.zoom_y=1.0
      plane=Plane.new(viewport); plane.bitmap=bitmap; plane.z=1
      plane.ox=37; plane.oy=29; plane.opacity=137
      check(scene,"workers=#{workers} plane")
      plane.dispose; plane=nil
      sprite.visible=false
      viewport.tone=Tone.new(23,-13,41,63)
      check(scene,"workers=#{workers} viewport_tone")
      viewport.tone=Tone.new; sprite.visible=true
    end
    ModLoader.parallel_renderer_frame_mode(0)
    state=ModLoader.parallel_renderer_frame_status
    raise 'OFF retained resources '+state unless state.include?('"memory_bytes":0') && state.include?('"worker_running":false')
    Map080Benchmark.log('RASTER_OFF_PASS '+state)
  ensure
    ModLoader.parallel_renderer_frame_mode(0)
    plane.dispose if plane && !plane.disposed?
    sprite.dispose if sprite && !sprite.disposed?
    viewport.dispose if viewport && !viewport.disposed?
    bitmap.dispose if bitmap && !bitmap.disposed?
  end
end
