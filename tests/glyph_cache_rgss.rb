# Native RGSS tests: compare full 32-bit bitmap dumps, then paired timings.
module GlyphCacheTest
  TEXTS = ['HP 1234 / 5678', 'Предметы и навыки: АБВ абв 0123456789',
           'A long menu description that needs horizontal compression',
           '日本語 Ελληνικά AV fi Wj', 'spaces    punctuation!? [] ()']
  MENU_TEXTS = ['Предметы', 'Навыки', 'Снаряжение', 'Статус', 'Сохранить',
                'HP 1234 / 5678', 'Атака 123', 'Защита 456', 'Деньги: 789', 'Назад']
  class << self
    def log(text); File.open('glyph-test.log', 'ab') { |f| f.write(text + "\n") }; end
    def assert(value, message); raise message unless value; end
    def status; ModLoader.glyph_cache_status; end
    def field(name); status[/"#{name}":(\d+)/, 1].to_i; end
    def pixels(bitmap, name)
      assert(ModLoader.dump_as_bmp(bitmap, name), 'dump failed')
      File.open(name, 'rb') { |f| f.read }
    end
    def configure(bitmap, index)
      font = bitmap.font
      font.name = ['Arial', 'Times New Roman', 'Consolas', 'VL Gothic'][index % 4]
      font.size = [12, 24, 36, 48][(index / 4) % 4]
      font.bold = index % 2 == 0
      font.italic = index % 3 == 0
      font.outline = index % 4 != 0
      font.shadow = index % 5 != 0
      font.color = Color.new(230, 115, 63, [80, 160, 255][index % 3])
      font.out_color = Color.new(12, 120, 200, 170)
    end
    def draw_case(bitmap, index)
      bitmap.clear
      bitmap.fill_rect(0, 0, bitmap.width, bitmap.height, Color.new(15, 30, 60, 110))
      configure(bitmap, index)
      text = TEXTS[index % TEXTS.size]
      width = [350, 90, 230][index % 3]
      bitmap.draw_text(-3, 2, width, 70, text, index % 3)
      bitmap.draw_text(Rect.new(4, 39, 280, 34), 'Overlap Жж AV', (index + 1) % 3)
      rect = bitmap.text_size(text)
      [rect.width, rect.height]
    end
    def correctness
      ModLoader.glyph_cache_clear
      bitmap = Bitmap.new(384, 80)
      64.times do |index|
        ModLoader.glyph_cache_enable(false)
        baseline_size = draw_case(bitmap, index)
        baseline = pixels(bitmap, 'glyph-off.bmp')
        ModLoader.glyph_cache_enable(true)
        size = draw_case(bitmap, index)
        cold = pixels(bitmap, 'glyph-on.bmp')
        assert(size == baseline_size && cold == baseline, "cold mismatch #{index}")
        size = draw_case(bitmap, index)
        warm = pixels(bitmap, 'glyph-on.bmp')
        assert(size == baseline_size && warm == baseline, "warm mismatch #{index}")
      end
      log('PIXELS PASS 64 cases cold+warm RGBA, fonts/styles/colors/clip/squeeze/overlap')
      # Keep all variants cached simultaneously, including recreated HFONTs.
      32.times { |i| draw_case(bitmap, i) }
      before = field('hits')
      32.times { |i| draw_case(bitmap, i) }
      log('FONT SWITCH STATUS ' + status)
      assert(field('hits') > before, 'no cache hits after font switching')
      bitmap.dispose
      log('FONT REUSE PASS ' + status)
    end
    def clock
      @qpc.call(@buffer)
      lo, hi = @buffer.unpack('L2')
      (lo + hi * 4294967296.0) * 1000.0 / @frequency
    end
    def timed(bitmap, enabled, iterations, kind)
      ModLoader.glyph_cache_enable(enabled)
      ModLoader.glyph_cache_clear
      40.times { work(bitmap, kind) }
      begin_at = clock
      iterations.times { work(bitmap, kind) }
      ms = clock - begin_at
      log("BENCH kind=#{kind} enabled=#{enabled} iterations=#{iterations} calls=#{iterations * (kind == :menu ? MENU_TEXTS.size : TEXTS.size)} ms=#{ms} status=#{status}")
      ms
    end
    def work(bitmap, kind)
      bitmap.clear if kind != :measure
      texts = kind == :menu ? MENU_TEXTS : TEXTS
      texts.each_with_index do |text, i|
        if kind == :measure
          bitmap.text_size(text)
        else
          bitmap.draw_text(0, (i % 5) * 48, kind == :squeeze ? 90 : 600, 48, text)
        end
      end
    end
    def benchmark
      @qpc = Win32API.new('kernel32', 'QueryPerformanceCounter', ['P'], 'I')
      api = Win32API.new('kernel32', 'QueryPerformanceFrequency', ['P'], 'I')
      @buffer = "\0" * 8
      api.call(@buffer); lo, hi = @buffer.unpack('L2')
      @frequency = lo + hi * 4294967296.0
      bitmap = Bitmap.new(640, 256)
      bitmap.font.name = 'Arial'; bitmap.font.size = 24
      bitmap.font.outline = true; bitmap.font.shadow = true
      [:draw, :measure, :squeeze, :menu].each do |kind|
        3.times do |round|
          order = round % 2 == 0 ? [false, true] : [true, false]
          order.each { |enabled| timed(bitmap, enabled, 300, kind) }
        end
      end
      bitmap.dispose
    end
    def bounded_memory
      bitmap = Bitmap.new(180, 160)
      bitmap.font.name = 'Arial'; bitmap.font.size = 96
      ModLoader.glyph_cache_enable(true)
      ModLoader.glyph_cache_clear
      assert(ModLoader.glyph_cache_limit_mib(1), 'limit rejected')
      1600.times do |i|
        bitmap.clear
        bitmap.draw_text(0, 0, 180, 160, [0x400 + i].pack('U'))
      end
      assert(field('owned_bytes') <= 1048576, 'memory limit exceeded')
      assert(field('evictions') > 0, 'eviction not exercised')
      log('MEMORY PASS ' + status)
      ModLoader.glyph_cache_enable(false)
      assert(field('entries') == 0 && field('payload_bytes') == 0, 'OFF retained cache')
      log('OFF PASS ' + status)
      ModLoader.glyph_cache_limit_mib(8)
      ModLoader.glyph_cache_enable(true)
      bitmap.dispose
    end
    def run
      log('RGSS ' + RUBY_VERSION)
      correctness
      benchmark
      bounded_memory
      File.open('glyph-test.result', 'wb') { |f| f.write('PASS') }
    rescue Exception => e
      log("FAIL #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
      File.open('glyph-test.result', 'wb') { |f| f.write('FAIL') }
      # Do not leave an unattended engine error dialog holding stage binaries.
    end
    def run_integration
      $glyph_reset_runs = ($glyph_reset_runs || 0) + 1
      log("RESET iteration=#{$glyph_reset_runs} " + status)
      assert(field('entries') == 0, 'cache survived F12') if $glyph_reset_runs > 1
      ModLoader.glyph_cache_enable(true)
      vp = Viewport.new(0, 0, 384, 80)
      sprite = Sprite.new(vp)
      bitmap = Bitmap.new(384, 80)
      sprite.bitmap = bitmap
      reference = Bitmap.new(384, 80)
      output = Bitmap.new(384, 80)
      probe = ModLoader::ParallelRenderer
      probe.optimization(2)
      12.times do |i|
        draw_case(bitmap, i)
        Graphics.update
        reference.clear; output.clear
        probe.reference(vp, reference)
        expected = pixels(reference, 'glyph-reference.bmp')
        probe.submit(vp, output, 8)
        # A queued snapshot must keep old pixels even if cached text is drawn
        # into the live bitmap before the worker result is collected.
        bitmap.draw_text(0, 0, 350, 60, 'Mutation after snapshot Ж')
        probe.collect(output)
        assert(pixels(output, 'glyph-worker.bmp') == expected, "worker mismatch #{i}")
      end
      log('WORKER PIXELS PASS cached text + mutation after capture ' + status)
      if $glyph_reset_runs == 1
        assert(field('entries') > 0, 'reset had no cached entries')
        log('Raising RGSSReset with populated glyph cache')
        raise RGSSReset
      end
      ModLoader.parallel_renderer_frame_mode(3)
      25.times do |i|
        bitmap.clear
        bitmap.draw_text(0, 0, 350, 60, "Menu text #{i} Ж")
        Graphics.update
      end
      native = ModLoader.parallel_renderer_frame_status
      assert(native.include?('"mode":3') && native.include?('"error":""'), native)
      log('RESET AND AUTOMATIC MODE3 PASS ' + native + ' cache=' + status)
      sprite.dispose; bitmap.dispose; reference.dispose; output.dispose; vp.dispose
      File.open('glyph-test.result', 'wb') { |f| f.write('PASS') }
    rescue Exception => e
      raise if e.is_a?(RGSSReset)
      log("FAIL #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
      File.open('glyph-test.result', 'wb') { |f| f.write('FAIL') }
    end
  end
end
