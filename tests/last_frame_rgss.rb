module LastFrameTest
  def self.run(scene)
    w,h=Graphics.width,Graphics.height
    source=Bitmap.new(w,h)
    sprite=Sprite.new
    sprite.z=2147483000
    sprite.bitmap=source
    results=[]
    begin
      [0,2,3].each do |mode|
        Graphics.transition(0)
        ModLoader.parallel_renderer_frame_mode(mode)
        source.fill_rect(source.rect,Color.new(30,180,70))
        16.times { Graphics.update }
        Map080Benchmark.log "LAST_FRAME mode=#{mode} #{ModLoader.last_frame_status}"
        baseline=Graphics.snap_to_bitmap
        source.fill_rect(source.rect,Color.new(200,40,60))
        before=ModLoader.parallel_renderer_frame_status
        old=Graphics.last_frame_to_bitmap
        raise 'Complete RGBA frame differs' unless ModLoader.parallel_renderer_pixels_equal(old,baseline)
        baseline.dispose
        color=old.get_pixel(w/2,h/2)
        raise "Did not copy previous frame: #{color.inspect}" unless [color.red,color.green,color.blue]==[30.0,180.0,70.0]
        raise 'Readback touched renderer queue' unless before==ModLoader.parallel_renderer_frame_status
        fresh=Graphics.snap_to_bitmap
        color=fresh.get_pixel(w/2,h/2)
        raise "Ordinary snapshot stale: #{color.inspect}" unless [color.red,color.green,color.blue]==[200.0,40.0,60.0]
        old.dispose; fresh.dispose
        SceneManager.snapshot_for_background
        color=SceneManager.background_bitmap.get_pixel(w/2,h/2)
        raise "Menu did not use old frame: #{color.inspect}" unless [color.red,color.green,color.blue]==[30.0,180.0,70.0]
        timings={}
        [:last_frame_to_bitmap,:snap_to_bitmap].each do |method|
          started=Time.now
          32.times { Graphics.send(method).dispose }
          timings[method]=(Time.now-started)*1000/32
        end
        ModLoader.last_frame_enable(false)
        missing=Bitmap.new(w,h)
        raise 'Disabled frame accepted' if ModLoader.last_frame_copy(missing)
        missing.dispose
        fallback=Graphics.last_frame_to_bitmap
        color=fallback.get_pixel(w/2,h/2)
        raise 'Fallback not current' unless color.red==200.0
        fallback.dispose
        ModLoader.last_frame_enable(true)
        ModLoader.parallel_renderer_frame_mode(0)
        sprite.visible=false
        # Measure the recurring capture overhead against the same live scene.
        overhead=[]
        [false,true].each do |enabled|
          ModLoader.last_frame_enable(enabled)
          8.times { Graphics.update }
          ModLoader.map_frame_probe_start
          64.times { Graphics.update }
          overhead << [enabled,ModLoader.map_frame_probe_stop]
        end
        sprite.visible=true
        results << {:mode=>mode,:snapshot_ms=>timings,:capture_overhead=>overhead}
        Map080Benchmark.log "LAST_FRAME mode=#{mode} pixels/menu/fallback PASS #{timings.inspect}"
      end
      # Title load/option menus use the same SceneManager background entry point.
      sprite.visible=false
      scene.pre_terminate
      scene.terminate
      scene.instance_variable_set(:@last_frame_test_terminated,true)
      SceneManager.goto(Scene_Title)
      title=SceneManager.scene
      title.start
      title.post_start
      8.times { title.update }
      state=ModLoader.last_frame_status
      shot=Graphics.last_frame_to_bitmap
      SceneManager.snapshot_for_background
      expected=shot.clone
      expected.blur
      raise 'Title menu background mismatch' unless ModLoader.parallel_renderer_pixels_equal(expected,SceneManager.background_bitmap)
      shot.dispose; expected.dispose
      title.pre_terminate
      title.terminate
      ModLoader.parallel_renderer_finish
      missing=Bitmap.new(w,h)
      raise 'Frame survived native reset' if ModLoader.last_frame_copy(missing)
      missing.dispose
      Map080Benchmark.log "LAST_FRAME title background PASS #{state}"
      File.open('last-frame-summary.dat','wb') { |f| f.write(Marshal.dump(results)) }
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      ModLoader.last_frame_enable(false)
      sprite.dispose
      source.dispose
    end
  end
end
