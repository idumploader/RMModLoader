module RenderSnapshotFreeze
  def self.run
    probe=ModLoader::ParallelRenderer
    w,h=Graphics.width,Graphics.height
    source=Bitmap.new(w,h)
    sprite=Sprite.new
    sprite.bitmap=source
    template,actual,expected=Array.new(3) { Bitmap.new(w,h) }
    begin
      probe.optimization(2)
      [0,3,2].each do |mode|
        raise 'Cannot select renderer mode' unless ModLoader.parallel_renderer_frame_mode(mode)
        [Color.new(230,30,40),Color.new(20,220,60),Color.new(30,50,230)].each_with_index do |color,cycle|
          Graphics.transition(0)
          source.fill_rect(source.rect,color)
          8.times { Graphics.update }
          Graphics.freeze
          # Make the frozen Surface the sole source of the visible image.
          sprite.visible=false
          if mode==0
            expected.clear
            probe.reference_frame(expected)
            probe.submit_frame(template)
            probe.collect(actual)
            raise "Stale frozen Surface mode=#{mode} cycle=#{cycle}" unless
              ModLoader.parallel_renderer_pixels_equal(expected,actual)
            c=actual.get_pixel(w/2,h/2)
            raise "Wrong frozen color #{c.inspect}" unless
              [c.red,c.green,c.blue]==[color.red,color.green,color.blue]
          else
            4.times { Graphics.update }
          end
          # snap_to_bitmap temporarily hides the freeze sprite and must capture
          # the current live tree rather than the frozen image.
          sprite.visible=true
          source.fill_rect(source.rect,Color.new(110,70,190))
          snap=Graphics.snap_to_bitmap
          begin
            c=snap.get_pixel(w/2,h/2)
            raise "Wrong snap color #{c.inspect}" unless [c.red,c.green,c.blue]==[110.0,70.0,190.0]
          ensure
            snap.dispose
          end
          Graphics.transition(3)
          state=ModLoader.parallel_renderer_frame_status
          raise state unless state.include?('"error":""') && state.include?("\"mode\":#{mode}")
          puts "FREEZE/SNAP mode=#{mode} cycle=#{cycle} pixel comparison PASS"
        end
      end
    ensure
      Graphics.transition(0)
      ModLoader.parallel_renderer_frame_mode(0)
      probe.clear
      sprite.dispose
      [source,template,actual,expected].each { |b| b.dispose }
    end
  end
end
