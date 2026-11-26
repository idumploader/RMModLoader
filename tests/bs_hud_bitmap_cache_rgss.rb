module BSHudCacheTest
  def self.check(value, message)
    raise message unless value
    Map080Benchmark.log("PASS #{message}")
  end
  def self.time
    start=Time.now.to_f
    yield
    (Time.now.to_f-start)*1000.0
  end
  def self.contents(window, file)
    ModLoader.dump_as_bmp(window.contents,file)
    File.open(file,'rb') { |f| f.read }
  end
  def self.run(scene)
    original=File.read('D:/workdir/codex/bsmp/.tools/hud-cache-original-455.rb')
    first=original.index('  def bsresolution_artwork(name)')
    last=original.index('  def bsresolution_gauge(',first)
    old=Class.new(Window_KisekiStatus)
    old.class_eval(original[first...last])
    old.class_eval do
      def dispose
        (@bsresolution_artwork || {}).each_value { |b| b.dispose unless b.disposed? }
        super
      end
    end
    BSHudBitmapCache.clear
    actor=$game_party.battle_members[0]
    saved=[actor.character_name,actor.character_index,actor.face_name,actor.face_index,actor.hp]
    stats={:resolution=>[Graphics.width,Graphics.height],:map=>$game_map.map_id,:party=>$game_party.battle_members.size,:pairs=>[]}
    [[saved[2],saved[3],false],[saved[2],(saved[3]+1)%8,false],['DS_Actor20',0,false],['DS_Actor20',0,true]].each_with_index do |data,i|
      actor.set_graphic(saved[0],saved[1],data[0],data[1])
      actor.hp=data[2] ? 0 : saved[4]
      previous=old.new
      fresh=Window_KisekiStatus.new
      check(ModLoader.parallel_renderer_pixels_equal(previous.contents,fresh.contents),"full RGBA contents face/index/dead case#{i}")
      previous.dispose; fresh.dispose
    end
    actor.set_graphic(saved[0],saved[1],'DS_Actor20',0); actor.hp=saved[4]
    BSHudBitmapCache.clear
    cold=nil
    stats[:cold_ms]=time { cold=Window_KisekiStatus.new }
    cold.dispose
    8.times do |i|
      values={}
      (i.even? ? [:old,:cached] : [:cached,:old]).each do |kind|
        window=nil
        values[kind]=time { window=(kind==:old ? old : Window_KisekiStatus).new }
        window.dispose
      end
      stats[:pairs] << values
    end
    stats[:cache]=BSHudBitmapCache.status
    stats[:warm_only]=[]
    8.times do
      window=nil
      stats[:warm_only] << time { window=Window_KisekiStatus.new }
      window.dispose
    end
    stats[:cache_after_warm]=BSHudBitmapCache.status
    Map080Benchmark.log("CACHE KEYS #{BSHudBitmapCache.instance_variable_get(:@entries).keys.map { |key| key.map { |value| value.is_a?(Bitmap) ? [value.object_id,value.hash,value.disposed?] : value } }.inspect}")
    check(stats[:cache_after_warm]==stats[:cache],'warm-only repeated windows do not grow cache')
    face=Cache.face(actor.face_name)
    check(!face.disposed?,'cached face remains borrowed')
    retained=nil
    BSHudBitmapCache.portrait(actor.face_name,actor.face_index,BSResolutionFix.pixels(48)) { |b| retained=b }
    Cache.clear
    check(retained.disposed?,'Cache.clear releases derived portrait')
    check(BSHudBitmapCache.status[:bytes]==0,'owned byte accounting returns to zero')
    rebuilt=Window_KisekiStatus.new
    rebuilt.dispose
    check(BSHudBitmapCache.status[:entries]>0,'HUD can rebuild after invalidation')
    BSHudBitmapCache.clear
    check(BSHudBitmapCache.status[:bytes]==0,'explicit reset releases artwork and portraits')
    File.open('hud-cache-summary.dat','wb') { |f| f.write(Marshal.dump(stats)) }
    Map080Benchmark.log("RESULT #{stats.inspect}")
  ensure
    actor.set_graphic(*saved[0,4]) if actor && saved
    actor.hp=saved[4] if actor && saved
    BSHudBitmapCache.clear
  end
end
