module MenuRenderingTest
  def self.equal(a,b,label)
    raise "RGBA mismatch #{label}" unless ModLoader.parallel_renderer_pixels_equal(a,b)
  end
  def self.measure
    started = Time.now
    yield
    (Time.now-started)*1000
  end
  def self.run(scene)
    control = ModLoader::MenuRendering
    results = {:resolution => [Graphics.width,Graphics.height], :samples => [], :menus => []}
    max_threads = ModLoader.respond_to?(:viewport_blur_max_threads) ? ModLoader.viewport_blur_max_threads : 1
    saved_threads = ModLoader.respond_to?(:viewport_blur_threads) ? ModLoader.viewport_blur_threads : 1
    begin
      raise 'Accepted nil as Bitmap' if ModLoader.menu_bitmap_blur(nil)
      viewport = Viewport.new
      raise 'Accepted Viewport as Bitmap' if ModLoader.menu_bitmap_blur(viewport)
      viewport.dispose
      disposed = Bitmap.new(3,3); disposed.dispose
      raise 'Accepted disposed Bitmap' if ModLoader.menu_bitmap_blur(disposed)
      subclass = Class.new(Bitmap).new(3,3)
      raise 'Accepted arbitrary native wrapper subclass' if ModLoader.menu_bitmap_blur(subclass)
      control.with_background { subclass.blur } # refusal must use original safely
      subclass.dispose
      # Random RGBA, transparent pixels, edges, odd sizes and RGSS small no-op.
      srand(74321)
      sizes = [[1,1],[2,9],[9,2],[3,3],[3,17],[17,3],[7,9],[31,19]]
      [1,max_threads].uniq.each do |threads|
        ModLoader.viewport_blur_threads = threads if ModLoader.respond_to?(:viewport_blur_threads=)
        sizes.each do |w,h|
          4.times do
            input = Bitmap.new(w,h)
            h.times { |y| w.times { |x| input.set_pixel(x,y,Color.new(rand(256),rand(256),rand(256),rand(256))) } }
            expected = input.clone; actual = input.clone
            expected.blur
            raise "Native blur refused #{w}x#{h} threads=#{threads}" unless ModLoader.menu_bitmap_blur(actual)
            equal(expected,actual,"random #{w}x#{h} threads=#{threads}")
            input.dispose; expected.dispose; actual.dispose
          end
        end
      end
      Map080Benchmark.log 'MENU_BLUR random/full RGBA/edge/small bitmap PASS'
      source = Graphics.last_frame_to_bitmap
      [1,max_threads].uniq.each do |threads|
        ModLoader.viewport_blur_threads = threads if ModLoader.respond_to?(:viewport_blur_threads=)
        8.times do |i|
          original = source.clone; fast = source.clone
          values = {}
          # Alternate order; input copies and pixel comparisons are outside timing.
          methods = i.even? ? [:original,:fast] : [:fast,:original]
          methods.each do |which|
            values[which] = measure do
              which == :original ? original.blur : (raise 'Native blur refused' unless ModLoader.menu_bitmap_blur(fast))
            end
          end
          equal(original,fast,"screen threads=#{threads} sample=#{i}")
          results[:samples] << {:threads=>threads,:trial=>i,:ms=>values}
          original.dispose; fast.dispose
        end
      end
      source.dispose
      ModLoader.viewport_blur_threads = saved_threads if ModLoader.respond_to?(:viewport_blur_threads=)
      [0,2,3].each do |mode|
        ModLoader.parallel_renderer_frame_mode(mode)
        16.times { Graphics.update }
        expected = Graphics.last_frame_to_bitmap
        expected.blur
        [false,true].each do |enabled|
          control.fast_blur = enabled
          ms = measure { SceneManager.snapshot_for_background }
          equal(expected,SceneManager.background_bitmap,"menu mode=#{mode} fast=#{enabled}")
          results[:menus] << {:renderer_mode=>mode,:fast_blur=>enabled,:snapshot_ms=>ms}
        end
        expected.dispose
        # Mutation must invalidate cached source versions and attached sprites;
        # queued frames own old pixels while the new bitmap is changed in place.
        canvas = Bitmap.new(Graphics.width,Graphics.height)
        half = Graphics.width / 2
        canvas.fill_rect(0,0,half,Graphics.height,Color.new(255,0,0))
        canvas.fill_rect(half,0,Graphics.width-half,Graphics.height,Color.new(0,255,0))
        sprite = Sprite.new; sprite.z = 2147483000; sprite.bitmap = canvas
        16.times { Graphics.update }
        expected = Graphics.last_frame_to_bitmap; expected.blur
        raise 'Visible bitmap blur refused' unless ModLoader.menu_bitmap_blur(canvas)
        16.times { Graphics.update }
        actual = Graphics.last_frame_to_bitmap
        equal(expected,actual,"visible mutation mode=#{mode}")
        actual.dispose; expected.dispose; sprite.dispose; canvas.dispose
      end
      # Actual map/menu lifecycle, stable render mode 3. Includes animation wait.
      results[:transitions] = []
      Window_MenuCommand.init_command_position
      ModLoader.parallel_renderer_frame_mode(3)
      [[:normal,false],[:normal,true],[:fast,true],[:off,true]].each do |transition,blur|
        control.transition_mode = transition; control.fast_blur = blur
        2.times do |trial|
          phases = {}
          phases[:map_terminate] = measure { scene.pre_terminate; scene.terminate }
          scene.instance_variable_set(:@menu_rendering_test_terminated,true)
          SceneManager.goto(Scene_Menu)
          menu = SceneManager.scene
          phases[:menu_start] = measure { menu.start }
          phases[:menu_transition] = measure { menu.post_start }
          4.times { menu.update }
          phases[:menu_terminate] = measure { menu.pre_terminate; menu.terminate }
          SceneManager.goto(Scene_Map)
          scene = SceneManager.scene
          phases[:map_start] = measure { scene.start }
          phases[:map_transition] = measure { scene.post_start }
          4.times { scene.update }
          results[:transitions] << {:transition=>transition,:fast_blur=>blur,:trial=>trial,:phases_ms=>phases}
        end
      end
      # Title/load path shares the same background interception.
      scene.pre_terminate; scene.terminate
      scene.instance_variable_set(:@menu_rendering_test_terminated,true)
      SceneManager.goto(Scene_Title)
      title = SceneManager.scene; title.start; title.post_start
      4.times { title.update }
      expected = Graphics.last_frame_to_bitmap; expected.blur
      SceneManager.snapshot_for_background
      equal(expected,SceneManager.background_bitmap,'title background')
      expected.dispose
      title.pre_terminate; title.terminate
      SceneManager.goto(Scene_Load)
      load_scene = SceneManager.scene; load_scene.start; load_scene.post_start
      4.times { load_scene.update }
      load_scene.pre_terminate; load_scene.terminate
      Map080Benchmark.log 'MENU_BLUR screen, renderer modes 0/2/3, menu/title, transitions PASS'
      File.open('menu-rendering-summary.dat','wb') { |f| f.write(Marshal.dump(results)) }
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      ModLoader.viewport_blur_threads = saved_threads if ModLoader.respond_to?(:viewport_blur_threads=)
      scene.terminate if scene && !scene.instance_variable_get(:@menu_rendering_test_terminated)
    end
  end
end
