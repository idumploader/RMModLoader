module RenderSnapshotScaledMap
  def self.run(scene)
    ModLoader.parallel_renderer_validation(true)
    probe=ModLoader::ParallelRenderer
    vp=scene.instance_variable_get(:@spriteset).instance_variable_get(:@viewport1)
    old_tone=vp.tone.clone
    fog=texture=nil
    blank=expected=actual=nil
    begin
      raise 'Expected original map size' unless ModLoader.hrfix_settings(false)[2]
      ModLoader.parallel_renderer_frame_mode(0)
      probe.optimization(2)
      blank,expected,actual=Array.new(3) { Bitmap.new(Graphics.width,Graphics.height) }
      texture=Bitmap.new(64,64)
      texture.fill_rect(0,0,64,64,Color.new(180,190,210,96))
      texture.fill_rect(8,8,24,24,Color.new(230,240,255,160))
      fog=Plane.new(vp)
      fog.bitmap=texture
      fog.z=500; fog.ox=17; fog.oy=31; fog.opacity=120
      [Tone.new(0,0,0,0),Tone.new(-60,-40,20,80),Tone.new(35,-20,-70,180)].each_with_index do |tone,index|
        vp.tone=tone
        texture.fill_rect(0,0,64,64,Color.new(180,190,210,96))
        texture.fill_rect(8,8,24,24,Color.new(230,240,255,160))
        expected.clear; actual.clear
        probe.reference_frame(expected)
        probe.capture_frame
        probe.draw(actual)
        raise "Scaled map + tone + fog mismatch #{index}" unless ModLoader.parallel_renderer_pixels_equal(actual,expected)
        probe.submit_frame(blank,3)
        # The pending job must retain both its tone and source dimensions.
        vp.tone=Tone.new(120,50,-40,255)
        vp.source_size(320,240)
        texture.clear
        probe.collect(actual)
        raise "Scaled snapshot mutated #{index}" unless ModLoader.parallel_renderer_pixels_equal(actual,expected)
        vp.source_size(640,480)
        puts "SCALED_MAP tone+Plane immutable PASS #{index}"
      end
      vp.tone=Tone.new(-60,-40,20,80)
      texture.fill_rect(0,0,64,64,Color.new(180,190,210,96))
      probe.clear
      [2,3].each do |mode|
        ModLoader.parallel_renderer_frame_mode(mode)
        40.times { scene.update; fog.ox+=1 }
        state=ModLoader.parallel_renderer_frame_status
        raise state unless state.include?("\"mode\":#{mode}") && state.include?('"checks":6') && state.include?('"error":""') && state.include?('"fallback":false')
        puts "SCALED_MAP automatic tone+Plane PASS #{state}"
        ModLoader.parallel_renderer_frame_mode(0)
      end
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      probe.clear
      vp.source_size(640,480)
      vp.tone=old_tone
      fog.dispose if fog
      [texture,blank,expected,actual].compact.each { |b| b.dispose }
    end
  end
end
