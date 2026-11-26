module ModMenuResolutionTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.shot(name)
    3.times { Graphics.update }
    bitmap = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(bitmap, "resolution-#{name}.bmp")
    bitmap.dispose
  end
  def self.run(scene)
    menu = ModMenu_ListWindow.new
    font = Graphics.width == 640 ? 22 : 25
    check(menu.contents.font.size == font, "root font #{font}")
    check(menu.width <= ModLoader::ModMenu.ui_pixels(800), 'root width capped')
    header = menu.instance_variable_get(:@header)
    description = menu.instance_variable_get(:@description_window)
    description.set('Readable description text at the selected resolution.')
    check(header.y >= 0 && description.y + description.height <= Graphics.height, 'panels fit screen')
    check(header.contents.font.size == font, 'header uses main font')
    check(description.contents.font.size == ModLoader::ModMenu.ui_pixels(20), 'description font')
    check(menu.line_height >= font, 'rows fit glyphs')
    shot('modmenu')
    item = ModLoader::ModMenu.submenu('Resolution check') do |m|
      m.header('Display')
      m.toggle('Names', :key => 'test.resolution.names', :default => true)
      m.slider('Size', :min => 8, :max => 32, :step => 2, :default => 16)
      m.choice('Mode', :values => [:a, :b], :default => :a)
      35.times { |i| m.header("Extra row #{i}") }
    end
    item.on_ok(menu)
    child = menu.child_window
    check(child.contents.font.size == font, 'submenu font')
    check(child.x >= 0 && child.x + child.width <= Graphics.width, 'submenu horizontal bounds')
    check(child.y >= 0 && child.y + child.height <= Graphics.height, 'submenu vertical bounds')
    shot('modmenu-submenu')
    child.select(child.item_max - 1)
    child.update
    check(child.top_row > 0, 'long submenu scrolls')
    check(child.cursor_rect.y + child.cursor_rect.height <= child.contents.height, 'last row cursor fits')
    menu.close_child
    check(child.disposed? && menu.active, 'close restores root')
    Map080Benchmark.log("GEOMETRY root=#{menu.width}x#{menu.height} font=#{font} line=#{menu.line_height} padding=#{menu.standard_padding}")
    menu.dispose
    ModLoader::ModMenu.on_close
  ensure
    menu.dispose if menu && !menu.disposed?
    ModLoader::ModMenu.on_close
  end
end
