module RenderSnapshotPlane
  def self.check_map(scene)
    probe=ModLoader::ParallelRenderer
    vp=scene.instance_variable_get(:@spriteset).instance_variable_get(:@viewport1)
    w,h=Graphics.width,Graphics.height
    blank,expected,actual=Array.new(3){Bitmap.new(w,h)}
    begin
      probe.optimization(2)
      probe.reference(vp,expected)
      raise 'Empty live viewport reference' if ModLoader.parallel_renderer_pixels_equal(expected,blank)
      probe.capture(vp)
      puts "MAP_PLANE capture #{probe.status}"
      probe.draw(actual)
      RenderSnapshotTilemap.equal!(actual,expected,'complete Map080 viewport snapshot')
      ModLoader.dump_as_bmp(actual,'map080-plane.bmp')
      2.times do |trial|
        (trial==0 ? [:original,:snapshot] : [:snapshot,:original]).each do |mode|
          ok=ModLoader.send("parallel_renderer_#{mode}_benchmark",vp,actual,60)
          raise probe.status unless ok
          RenderSnapshotTilemap.equal!(actual,expected,"complete viewport #{mode}")
          puts "PLANE_BENCH #{w},#{h},#{trial},#{mode} #{probe.status}"
        end
      end
      probe.submit(vp,blank,40)
      15.times { scene.update }
      probe.collect(actual)
      RenderSnapshotTilemap.equal!(actual,expected,'complete viewport frozen during scene updates')
      puts "MAP_PLANE PASS #{w}x#{h} #{probe.status}"
    ensure
      probe.clear
      [blank,expected,actual].each { |b| b.dispose }
    end
  end
  def self.run
    probe=ModLoader::ParallelRenderer
    resources=[]
    begin
      vp=Viewport.new(7,11,119,83)
      plane=Plane.new(vp)
      bitmap=Bitmap.new(17,13)
      resources.concat([vp,plane,bitmap])
      bitmap.fill_rect(bitmap.rect,Color.new(200,50,100,190))
      bitmap.fill_rect(2,3,7,6,Color.new(20,230,60,255))
      bitmap.set_pixel(0,0,Color.new(0,50,240,70))
      plane.bitmap=bitmap
      blank,expected,actual,newer=Array.new(4){Bitmap.new(137,101)}
      blank.fill_rect(blank.rect,Color.new(19,33,47,80))
      resources.concat([blank,expected,actual,newer])
      [0,1,2].each do |mode|
        probe.clear; probe.optimization(mode)
        12.times do |i|
          vp.ox, vp.oy= i*7-26, i*11-31
          plane.ox, plane.oy= i*13-45, i*9-37
          plane.zoom_x=[1.0,0.5,1.25,2.0][i%4]
          plane.zoom_y=[1.0,1.5,0.75][i%3]
          plane.opacity=90+i*13
          plane.blend_type=i%3
          plane.tone=Tone.new(40,-30,20,i%2==0 ? 80 : 0)
          plane.color=Color.new(70,100,220,i%2==0 ? 0 : 60)
          Graphics.update
          expected.blt(0,0,blank,blank.rect,255)
          # blt blends, so use fresh clones for identical backgrounds.
          expected.dispose; actual.dispose
          expected=blank.clone; actual=blank.clone
          resources.concat([expected,actual])
          probe.reference(vp,expected)
          probe.capture(vp); probe.draw(actual)
          RenderSnapshotTilemap.equal!(actual,expected,"Plane sync #{mode}/#{i}")
          probe.start(blank,100)
          vp.ox+=3; plane.oy+=5
          Graphics.update
          probe.collect(actual)
          RenderSnapshotTilemap.equal!(actual,expected,"Plane worker #{mode}/#{i}")
        end
        puts "Plane mode=#{mode}: zoom/scroll/viewport origin/tone/color/opacity/blend PASS"
      end
      expected.dispose; expected=blank.clone; resources<<expected
      Graphics.update; probe.reference(vp,expected)
      probe.submit(vp,blank,1000)
      bitmap.clear
      vp.ox=90; vp.oy=-75
      Graphics.update
      newer.dispose; newer=blank.clone; resources<<newer
      probe.reference(vp,newer)
      raise 'Plane mutation produced no difference' if ModLoader.parallel_renderer_pixels_equal(expected,newer)
      probe.submit(vp,blank,1000)
      plane.dispose; bitmap.dispose; vp.dispose; GC.start
      # Create another registered viewport while old frames are rendering.
      replacement=Viewport.new(0,0,128,96); resources<<replacement
      replacement.ox=999
      5.times { Graphics.update }
      probe.collect(actual); RenderSnapshotTilemap.equal!(actual,expected,'Plane old version after dispose')
      probe.collect(actual); RenderSnapshotTilemap.equal!(actual,newer,'Plane new version after dispose')
      puts 'Plane FIFO mutation/disposal/global registry independence PASS'
    ensure
      probe.clear
      resources.reverse_each { |r| r.dispose unless r.disposed? }
    end
  end
end
