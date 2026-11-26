# Run in native RGSS with the snapshot probe; never standalone Ruby.
module RenderSnapshotTilemap
  def self.check_map(scene)
    probe = ModLoader::ParallelRenderer
    spriteset = scene.instance_variable_get(:@spriteset)
    live = spriteset.instance_variable_get(:@tilemap)
    # Use the real map's tables/atlases in a dedicated viewport. The complete
    # scene contains Plane nodes whose native renderer reads a global live list.
    vp = Viewport.new(0,0,Graphics.width,Graphics.height)
    tile = Tilemap.new(vp)
    tile.map_data = live.map_data
    tile.flags = live.flags
    tile.flash_data = live.flash_data
    9.times { |i| tile.bitmaps[i] = live.bitmaps[i] }
    tile.ox, tile.oy = live.ox, live.oy
    sprites = spriteset.instance_variable_get(:@character_sprites).map do |source|
      target = Sprite.new(vp)
      target.bitmap = source.bitmap
      target.src_rect = source.src_rect
      [:x,:y,:z,:ox,:oy,:zoom_x,:zoom_y,:angle,:mirror,:opacity,:blend_type,:visible,:bush_depth,:tone,:color,:wave_amp,:wave_length,:wave_speed,:wave_phase].each do |key|
        target.send("#{key}=",source.send(key))
      end
      target
    end
    Graphics.update
    w,h = Graphics.width,Graphics.height
    reference, actual, blank = Array.new(3) { Bitmap.new(w,h) }
    begin
      probe.optimization(2)
      probe.reference(vp,reference)
      raise 'Map080 reference is empty' if ModLoader.parallel_renderer_pixels_equal(reference,blank)
      probe.capture(vp)
      puts "MAP_TILE capture #{probe.status}"
      probe.draw(actual)
      equal!(actual,reference,'Map080 Tilemap viewport')
      raise 'Could not save Tilemap screenshot' unless ModLoader.dump_as_bmp(actual,'map080-tilemap.bmp')
      puts "MAP_TILE scene=#{w}x#{h} characters=#{sprites.size}"
      # Equal native clear+draw loops; copying, logic and presentation excluded.
      2.times do |trial|
        order = trial==0 ? [:original,:snapshot] : [:snapshot,:original]
        order.each do |mode|
          ok = ModLoader.send("parallel_renderer_#{mode}_benchmark",vp,actual,120)
          raise probe.status unless ok
          equal!(actual,reference,"Map080 #{mode} benchmark")
          puts "TILE_BENCH #{w},#{h},#{trial},#{mode} #{probe.status}"
        end
      end
      probe.submit(vp,blank,20)
      15.times { scene.update; tile.update }
      probe.collect(actual)
      equal!(actual,reference,'Map080 frozen during live scene updates')
      puts "MAP_TILE PASS #{w}x#{h} #{probe.status}"
    ensure
      probe.clear
      sprites.each { |s| s.dispose }
      tile.dispose
      vp.dispose
      [reference,actual,blank].each { |b| b.dispose }
    end
  end
  def self.equal!(a, b, label)
    unless ModLoader.parallel_renderer_pixels_equal(a, b)
      ModLoader.dump_as_bmp(a, 'tilemap-actual.bmp')
      ModLoader.dump_as_bmp(b, 'tilemap-expected.bmp')
      raise "#{label}: pixels differ"
    end
  end

  def self.run
    probe = ModLoader::ParallelRenderer
    resources = []
    begin
      vp = Viewport.new(5, 7, 630, 466)
      tile = Tilemap.new(vp)
      resources.concat([vp, tile])
      atlases = Array.new(9) do |i|
        bitmap = Bitmap.new(512, 768)
        48.times do |y|
          32.times do |x|
            bitmap.fill_rect(x*16, y*16, 16, 16, Color.new((x*37+i*43)%256, (y*29+i*61)%256, (x*11+y*17)%256, (x+y)%3==0 ? 150 : 255))
          end
        end
        resources << bitmap
        tile.bitmaps[i] = bitmap
        bitmap
      end
      map = Table.new(40, 40, 4)
      flags = Table.new(8192)
      flash = Table.new(40, 40)
      8192.times { |i| flags[i] = (i%2==0 ? 0x10 : 0) | (i%3==0 ? 0x80 : 0) }
      40.times do |y|
        40.times do |x|
          map[x,y,0] = 2048 + ((x+y*40)%128)*48 + (x*7+y*11)%48
          map[x,y,1] = y%2==0 ? 2816+(x%24)*48+(y*3+x)%48 : 0
          map[x,y,2] = 1+(x*17+y*53)%1023
          map[x,y,3] = (x+y)%16
          flash[x,y] = (x%5==0 && y%3==0) ? 0xa73 : 0
        end
      end
      tile.map_data, tile.flags, tile.flash_data = map, flags, flash
      sprite = Sprite.new(vp)
      sprite.bitmap = atlases[5]
      sprite.src_rect.set(0,0,45,57)
      sprite.x, sprite.y, sprite.z = 65, 55, 100
      resources << sprite
      reference, actual, blank, newer = Array.new(4) { Bitmap.new(640,480) }
      resources.concat([reference,actual,blank,newer])
      [0,1,2].each do |mode|
        probe.clear
        probe.optimization(mode)
        [[0,0,0], [7,13,30], [325,279,60], [-9,-17,90]].each do |ox,oy,steps|
          steps.times { tile.update }
          tile.ox, tile.oy = ox, oy
          Graphics.update
          reference.clear; actual.clear
          probe.reference(vp,reference)
          raise 'Empty reference' if ModLoader.parallel_renderer_pixels_equal(reference,blank)
          probe.capture(vp)
          raise 'Tilemap was not shared by its two layers' unless probe.status.include?('"tilemaps":1')
          probe.draw(actual)
          equal!(actual,reference,"mode=#{mode} offset=#{ox},#{oy}")
          probe.start(blank, 40)
          3.times { tile.update; Graphics.update }
          probe.collect(actual)
          equal!(actual,reference,'animation frozen in worker')
        end
        puts "Tilemap sync/worker mode=#{mode}: offsets, autotiles, stars, tables, shadows, flash PASS"
      end
      # Two versions while live map and tileset mutate, then dispose originals.
      tile.ox=0; tile.oy=0
      Graphics.update
      reference.clear
      probe.reference(vp,reference)
      probe.submit(vp,blank,100)
      map[1,1,0]=1536
      flags[map[1,1,2]]=0x10
      flash[1,1]=0xfff
      atlases[0].fill_rect(atlases[0].rect,Color.new(255,0,20))
      tile.ox=9
      Graphics.update
      newer.clear
      probe.reference(vp,newer)
      raise 'Mutation did not affect reference' if ModLoader.parallel_renderer_pixels_equal(reference,newer)
      probe.submit(vp,blank,100)
      vp.rect.set(0,0,64,64) # force different live HRFix loop bounds during replay
      Graphics.update
      sprite.dispose; tile.dispose; vp.dispose
      atlases.each { |b| b.dispose }
      map=flags=flash=nil
      GC.start
      5.times { Graphics.update }
      probe.collect(actual); equal!(actual,reference,'old queued map after mutation/dispose')
      probe.collect(actual); equal!(actual,newer,'new queued map after dispose')
      puts "Tilemap FIFO table/atlas versions + dispose/GC PASS #{probe.status}"
    ensure
      probe.clear
      resources.reverse_each { |r| r.dispose unless r.disposed? }
    end
  end
end
