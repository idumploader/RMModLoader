# Isolated native fixture: real RGSS sprites/bitmaps, standard picture lifecycle.
class Game_Picture
  attr_accessor :name, :origin, :x, :y, :zoom_x, :zoom_y, :opacity
  def show(name, origin, x, y, zx, zy, opacity = 255, blend = 0)
    @name, @origin, @x, @y, @zoom_x, @zoom_y, @opacity = name, origin, x, y, zx, zy, opacity
  end
end
class Sprite_Picture < Sprite
  def initialize(viewport, picture, source)
    super(viewport)
    @picture = picture
    @source = source
  end
  def update
    self.bitmap = @picture.name.empty? ? nil : @source
    self.ox = @picture.origin == 1 ? @source.width / 2 : 0
    self.oy = @picture.origin == 1 ? @source.height / 2 : 0
    self.z = 10
    self.opacity = @picture.opacity
  end
end
module Cache
  def self.load_bitmap(*args); end
end
class Scene_Map; end
eval(File.read('D:/workdir/codex/bsmp/RMModLoader/mod_loader/scripts/500 - GraphicsReplace.rb'))
eval(File.read('D:/workdir/codex/bsmp/RMModLoader/mod_loader/framework/renderer/hrfix_pictures.rb'))

module SceneManager
  def self.run
  begin
  raise 'wrong resolution' unless [Graphics.width, Graphics.height] == [1920, 1080]
  viewport = Viewport.new
  red = Bitmap.new(1, 1)
  red.fill_rect(red.rect, Color.new(255, 0, 0))
  background = Sprite.new(viewport)
  background.bitmap = red
  background.zoom_x, background.zoom_y = Graphics.width, Graphics.height
  background.z = 9
  low = Bitmap.new(640, 480)
  low.fill_rect(low.rect, Color.new(0, 255, 0))
  high = Bitmap.new(1280, 960)
  high.fill_rect(high.rect, Color.new(0, 255, 0))
  high.graphics_replace_set_sizes([640, 480])
  picture = Game_Picture.new
  snapshots = []
  [low, high].each do |source|
    picture.show('full', 0, 0, 0, 100, 100)
    image = Sprite_Picture.new(viewport, picture, source)
    image.update
    Graphics.update
    snap = Graphics.snap_to_bitmap
    raise 'left bar leaks map' unless snap.get_pixel(100, 500).red == 0
    raise 'right bar leaks map' unless snap.get_pixel(1800, 500).red == 0
    raise 'image missing' unless snap.get_pixel(960, 540).green == 255
    snapshots << snap
    if source == high
      above = Sprite.new(viewport)
      above.bitmap = red
      above.z = 11
      above.zoom_x = above.zoom_y = 150
      Graphics.update
      sample = Graphics.snap_to_bitmap
      raise 'bar covers upper picture' unless sample.get_pixel(100, 100).red == 255
      sample.dispose
      above.dispose
      picture.name = ''
      image.update
      Graphics.update
      sample = Graphics.snap_to_bitmap
      raise 'erase left stale bars' unless sample.get_pixel(100, 500).red == 255
      sample.dispose
    end
    image.dispose
  end
  raise 'HD output differs' unless ModLoader.parallel_renderer_pixels_equal(*snapshots)
  File.open('result.txt', 'wb') { |f| f.write('PASS native bars, layering, erase, original/HD full RGBA') }
rescue Exception => error
  File.open('result.txt', 'wb') { |f| f.write("FAIL #{error}\n#{error.backtrace.join("\n")}") }
end

  end
end
rgss_main { SceneManager.run }
