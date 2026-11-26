module RenderSnapshotObjects
  def self.run
    ModLoader.parallel_renderer_validation(true)
    probe=ModLoader::ParallelRenderer
    resources=[]
    begin
      vp=Viewport.new(5,9,180,140); resources<<vp
      source=Bitmap.new(48,40); resources<<source
      source.fill_rect(source.rect,Color.new(210,70,35,200))
      source.fill_rect(9,4,15,22,Color.new(20,170,230,255))
      sprite=Sprite.new(vp); resources<<sprite
      sprite.bitmap=source; sprite.x=75; sprite.y=65; sprite.ox=17; sprite.oy=12
      blank=Bitmap.new(200,160); actual=Bitmap.new(200,160)
      resources.concat([blank,actual])
      [0,1,2].each do |mode|
        probe.clear; probe.optimization(mode)
        [15,90,-35,180,270,359,0].each_with_index do |angle,i|
          sprite.angle=angle; sprite.zoom_x=0.75+i*0.1; sprite.zoom_y=1.25
          sprite.mirror=(i%2==0); vp.ox=i*3; vp.oy=-i*2
          sprite.tone=Tone.new(15,-20,35,20); sprite.color=Color.new(20,60,220,35)
          sprite.wave_amp=(i%3==0 ? 4 : 0); sprite.wave_length=28
          source.set_pixel(i,i,Color.new(0,255,20,255))
          Graphics.update
          expected=blank.clone; resources<<expected
          # Capture before reference, so lazy cache preparation is exercised.
          probe.capture(vp); actual.clear; probe.draw(actual)
          probe.reference(vp,expected)
          RenderSnapshotTilemap.equal!(actual,expected,"rotation sync #{mode}/#{angle}")
          probe.start(blank,100)
          sprite.angle+=23; source.clear; Graphics.update
          probe.collect(actual)
          RenderSnapshotTilemap.equal!(actual,expected,"rotation worker #{mode}/#{angle}")
          source.fill_rect(source.rect,Color.new(210,70,35,200))
        end
        puts "Rotation mode=#{mode}: angle/zoom/mirror/scroll/wave/tone/cache mutation PASS"
      end
      [2,3].each do |mode|
        raise probe.status unless ModLoader.parallel_renderer_frame_mode(mode)
        30.times do |i|
          sprite.angle=i*13+5
          vp.ox=i; vp.oy=-i
          Graphics.update
        end
        state=ModLoader.parallel_renderer_frame_status
        raise state unless state.include?('"checks":6') && state.include?('"error":""') && state.include?("\"mode\":#{mode}")
        puts "Rotation automatic #{mode} PASS #{state}"
        ModLoader.parallel_renderer_frame_barrier
        raise 'barrier left an old frame' unless probe.status.include?('"queue_depth":0')
        ModLoader.parallel_renderer_frame_mode(0)
      end
      sprite.angle=43; Graphics.update
      frozen=blank.clone; resources<<frozen
      probe.reference(vp,frozen); probe.submit(vp,blank,1000)
      sprite.dispose; source.dispose; GC.start
      5.times { Graphics.update }
      probe.collect(actual)
      RenderSnapshotTilemap.equal!(actual,frozen,'Rotation after original disposal/GC')
      puts 'Rotation disposal/GC PASS'
      window=Window.new(15,18,135,105); resources<<window
      window.viewport=vp
      skin=Bitmap.new(128,128); resources<<skin
      skin.fill_rect(skin.rect,Color.new(80,130,170,255))
      skin.fill_rect(64,0,64,64,Color.new(210,70,80,180))
      window.windowskin=skin
      contents=Bitmap.new(180,140); resources<<contents
      contents.fill_rect(contents.rect,Color.new(30,200,70,170))
      contents.draw_text(0,0,160,30,'Snapshot window')
      window.contents=contents
      [0,1,2].each do |mode|
        probe.clear; probe.optimization(mode)
        10.times do |i|
          window.openness=[255,128,0,200][i%4]
          window.opacity=255-i*8; window.back_opacity=100+i*12
          window.contents_opacity=220-i*9
          window.ox=i*4; window.oy=i*3
          window.width=135+i/3; window.height=105+i/3
          window.cursor_rect.set(i*3,i*2,40,20)
          window.active=(i%2==0); window.pause=(i%3==0)
          skin.fill_rect(0,0,32,32,Color.new(i*20,140,90,210))
          contents.fill_rect(i*5,35,12,22,Color.new(200,10*i,70,255))
          window.update; Graphics.update
          expected=blank.clone; resources<<expected
          probe.capture(vp); actual.clear; probe.draw(actual)
          probe.reference(vp,expected)
          RenderSnapshotTilemap.equal!(actual,expected,"Window sync #{mode}/#{i}")
          probe.start(blank,100)
          window.openness=255; window.ox+=11; window.update; Graphics.update
          probe.collect(actual)
          RenderSnapshotTilemap.equal!(actual,expected,"Window worker #{mode}/#{i}")
        end
        puts "Window mode=#{mode}: openness/opacity/scroll/cursor/resize/skin/content PASS"
      end
      Graphics.update
      expected=blank.clone; resources<<expected
      probe.reference(vp,expected); probe.submit(vp,blank,1000)
      window.dispose; skin.dispose; contents.dispose; vp.dispose; GC.start
      5.times { Graphics.update }
      probe.collect(actual)
      RenderSnapshotTilemap.equal!(actual,expected,'Window after original disposal/GC')
      puts 'Window disposal/GC PASS'
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      probe.clear
      resources.reverse_each { |r| r.dispose unless r.disposed? }
    end
  end
end
