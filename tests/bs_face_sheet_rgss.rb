module BSFaceSheetTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.equal(a, b, label)
    check(ModLoader.parallel_renderer_pixels_equal(a, b), label)
  end
  def self.run(scene)
    name = "\u841d\u65af\u6885\u53ef (2)"
    check(Cache.face(name).width == 1536 && Cache.face(name).height == 768,
      'GraphicsReplace loads HD sheet')
    low = Bitmap.new(384, 192)
    8.times do |i|
      low.fill_rect(i % 4 * 96, i / 4 * 96, 96, 96,
        Color.new(30 + i * 25, 220 - i * 20, 40 + i * 20))
      low.fill_rect(i % 4 * 96 + 20, i / 4 * 96 + 38, 40, 24,
        Color.new(240, 35 + i * 20, 130))
    end
    high = Bitmap.new(1536, 768)
    high.stretch_blt(high.rect, low, low.rect)
    window = Window_Base.new(0, 0, 230, 230)
    reference = Bitmap.new(window.contents.width, window.contents.height)
    singleton = class << Cache; self; end
    original = Cache.method(:face)
    source = high
    singleton.send(:define_method, :face) do |file|
      file == '__face_sheet_test' ? source : original.call(file)
    end
    8.times do |index|
      source = high
      window.contents.clear; reference.clear
      window.draw_face('__face_sheet_test', index, 3, 7, false)
      reference.blt(3, 7, low, Rect.new(index % 4 * 96, index / 4 * 96, 96, 96), window.translucent_alpha)
      equal(window.contents, reference, "base HD index#{index} opacity full RGBA")
      [true, false].each do |enabled|
        BattlePortraitCacheFix.enabled = enabled
        source = high
        window.contents.clear; reference.clear
        window.draw_battle_face('__face_sheet_test', index, 3, 7)
        reference.blt(3, 7, low, Rect.new(index % 4 * 96 + ED::BTL_FACE_RECT_X,
          index / 4 * 96 + ED::BTL_FACE_RECT_Y, ED::BTL_FACE_RECT_WIDTH, ED::BTL_FACE_RECT_HEIGHT))
        equal(window.contents, reference, "battle HD index#{index} cache#{enabled} full RGBA")
        if !enabled
          check(high.disposed?, 'cache OFF preserves disposal')
          high = Bitmap.new(1536, 768); high.stretch_blt(high.rect, low, low.rect)
        end
      end
    end
    source = high
    BattlePortraitCacheFix.enabled = true
    if defined?(BSResolutionFix)
      [BSResolutionFix::CanvasWindow, BSResolutionFix::NativeActorDrawing].each do |drawing|
        klass = Class.new(Window_Base)
        klass.send(:include, drawing)
        menu = klass.new(0, 0, 230, 230)
        actor = Struct.new(:face_name, :face_index).new('__face_sheet_test', 3)
        if drawing == BSResolutionFix::CanvasWindow
          menu.instance_variable_set(:@bsresolution_canvas_scale, BSResolutionFix.scale)
          menu.instance_variable_set(:@bsresolution_drawing_canvas, true)
          menu.draw_actor_face(actor, 0, 0, false)
          actual = menu.contents.instance_variable_get(:@bitmap)
          size = BSResolutionFix.pixels(96)
        else
          size = BSResolutionFix.pixels(96)
          menu.bsresolution_face(actor, 0, 0, size, false)
          actual = menu.contents
        end
        expected = Bitmap.new(actual.width, actual.height)
        expected.stretch_blt(Rect.new(0, 0, size, size), low, Rect.new(288, 0, 96, 96), menu.translucent_alpha)
        equal(actual, expected, "#{drawing} HD full RGBA")
        expected.dispose; menu.dispose
      end
    end
    [48, 80].each do |size|
      source = low
      old = nil
      BSHudBitmapCache.portrait('__face_sheet_test', 3, size) { |b| old = b.clone }
      source = high
      BSHudBitmapCache.portrait('__face_sheet_test', 3, size) do |b|
        equal(old, b, "HUD HD portrait#{size} full RGBA")
      end
      old.dispose
    end
    message = Window_Message.new
    4.times do |index|
      message.contents.clear
      expected = Bitmap.new(message.contents.width, message.contents.height)
      size = defined?(BSResolutionFix) ? BSResolutionFix.pixels(96) : 96
      # Suppress only the separate name window while checking the face itself.
      message.define_singleton_method(:show_name_window) { |*_| }
      message.draw_face('__face_sheet_test', index, 0, 0)
      expected.stretch_blt(Rect.new(0, 0, size, size), low, Rect.new(index * 96, 0, 96, 96))
      equal(message.contents, expected, "message HD index#{index} full RGBA")
      expected.dispose
    end
    [:Window_SptActor, :Window_SptSpirit].each do |constant|
      next unless Object.const_defined?(constant)
      klass = Class.new(Object.const_get(constant))
      klass.send(:define_method, :initialize) do
        Window_Base.instance_method(:initialize).bind(self).call(0, 0, 230, 230)
      end
      partner = klass.new
      height = partner.line_height * (constant == :Window_SptActor ? 1 : 2)
      partner.draw_face('__face_sheet_test', 3, 0, 0, false)
      expected = Bitmap.new(partner.contents.width, partner.contents.height)
      expected.blt(0, 0, low, Rect.new(288, (96-height)/2, 96, height), partner.translucent_alpha)
      equal(partner.contents, expected, "#{constant} centred crop full RGBA")
      expected.dispose; partner.dispose
    end
    source = Bitmap.new(96, 96)
    check(BSFaceSheet.rect(source, 0).width == 96, 'square single-face file')
    source.dispose; source = high
    check(!high.disposed?, 'cache ON retains borrowed source')
    Map080Benchmark.log('HD FACE SHEET COMPLETE')
  ensure
    singleton.send(:define_method, :face) { |file| original.call(file) } if singleton && original
    BattlePortraitCacheFix.enabled = true
    [low, high, window, reference, message].each { |object| object.dispose if object && !object.disposed? }
  end
end
