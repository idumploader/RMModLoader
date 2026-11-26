require 'minitest/autorun'
module Graphics
  class << self; attr_accessor :width, :height; end
  self.width = 1920
  self.height = 1080
end
module ModLoader
  def self.data_directory; File.expand_path('../mod_loader', __dir__); end
end
Color = Struct.new(:red, :green, :blue, :alpha)
class Bitmap
  attr_reader :width, :height
  class << self; attr_accessor :loads, :instances, :missing_original; end
  self.loads = []; self.instances = []
  def initialize(w, h = nil)
    if h
      @width, @height = w, h
    else
      self.class.loads << w
      raise 'missing original' if self.class.missing_original && w == 'Graphics/Pictures/full'
      @width, @height = w.start_with?(GraphicsReplace::REPLACE_DIR) ? [1280, 960] : [640, 480]
    end
    self.class.instances << self
  end
  def fill_rect(*args); end
  def disposed?; !!@disposed; end
  def dispose; @disposed = true; end
end
module Cache
  @cache = {}
  def self.load_bitmap(*args); end
  def self.include?(path); @cache[path] && !@cache[path].disposed?; end
end
class Scene_Map; end
class Game_Picture
  attr_accessor :name, :origin, :x, :y, :zoom_x, :zoom_y, :opacity
  def show(name, origin, x, y, zx, zy, opacity = 255, blend = 0)
    @name, @origin, @x, @y, @zoom_x, @zoom_y, @opacity = name, origin, x, y, zx, zy, opacity
  end
end
class Sprite
  attr_accessor :bitmap, :viewport, :x, :y, :zoom_x, :zoom_y, :z, :opacity, :visible
  def initialize(viewport = nil); @viewport = viewport; @visible = true; end
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
class Sprite_Picture < Sprite
  def initialize(picture, bitmap)
    super(:picture_viewport)
    @picture = picture
    self.bitmap = bitmap
  end
  def update; self.z = 10; self.opacity = @picture.opacity; end
end
load File.expand_path('../mod_loader/scripts/500 - GraphicsReplace.rb', __dir__)
load File.expand_path('../mod_loader/framework/renderer/hrfix_pictures.rb', __dir__)

class HRFixPicturesTest < Minitest::Test
  def setup
    Graphics.width, Graphics.height = 1920, 1080
    Bitmap.missing_original = false
  end
  def sprite(w = 640, h = 480, x = 0, y = 0, origin = 0)
    picture = Game_Picture.new
    picture.show('full', origin, x, y, 100, 100)
    bitmap = Bitmap.new(w, h)
    [Sprite_Picture.new(picture, bitmap), picture]
  end
  def test_fullscreen_original_and_hd_replacement_have_identical_bounds
    normal, = sprite
    hd, = sprite(1280, 960)
    hd.bitmap.graphics_replace_set_sizes([640, 480])
    [normal, hd].each(&:update)
    assert_equal [240, 0], [normal.x, normal.y]
    assert_equal [normal.x, normal.y], [hd.x, hd.y]
    assert_equal 1440, normal.bitmap.width * normal.zoom_x
    assert_equal 1440, hd.bitmap.width * hd.zoom_x
    assert_equal 1080, hd.bitmap.height * hd.zoom_y
    assert_equal [240, 240, 1440, 1440], hd.instance_variable_get(:@hrfix_picture_bars).map(&:zoom_x)
  end
  def test_center_origin_and_move_keep_logical_coordinates
    image, picture = sprite(640, 480, 320, 240, 1)
    image.update
    assert picture.hrfix_fullscreen
    assert_equal [960, 540], [image.x, image.y]
    picture.x = 300
    image.update
    assert_equal 300, picture.x
    assert_equal 915, image.x
  end
  def test_small_picture_is_not_centered_or_normalized_to_fullscreen
    image, picture = sprite(100, 200, 20, 30)
    image.update
    refute picture.hrfix_fullscreen
    assert_equal [60, 67.5], [image.x, image.y]
    assert_equal [3, 2.25], [image.zoom_x, image.zoom_y]
    assert_nil image.instance_variable_get(:@hrfix_picture_bars)
  end
  def test_offscreen_large_picture_is_not_fullscreen
    image, picture = sprite(640, 480, 80, 0)
    image.update
    refute picture.hrfix_fullscreen
  end
  def test_opacity_erase_reshow_and_disposal
    image, picture = sprite
    picture.opacity = 73
    image.update
    bars = image.instance_variable_get(:@hrfix_picture_bars)
    assert_equal [73] * 4, bars.map(&:opacity)
    assert_equal [10] * 4, bars.map(&:z)
    picture.name = ''
    image.update
    assert bars.none?(&:visible)
    picture.show('full', 0, 80, 0, 100, 100)
    image.update
    refute picture.hrfix_fullscreen
    assert bars.none?(&:visible)
    backing = image.instance_variable_get(:@hrfix_bar_bitmap)
    image.dispose
    assert bars.all?(&:disposed?)
    assert backing.disposed?
  end
  def test_four_by_three_screen_needs_no_bars
    Graphics.width, Graphics.height = 1280, 960
    image, = sprite
    image.update
    assert_equal [0, 0, 2, 2], [image.x, image.y, image.zoom_x, image.zoom_y]
    assert_nil image.instance_variable_get(:@hrfix_picture_bars)
  end
  def test_cache_records_original_size_once_and_disposes_probe
    path = 'Graphics/Pictures/full'
    Cache.instance_variable_set(:@cache, {})
    Bitmap.loads.clear
    replacement_path = GraphicsReplace::REPLACE_DIR + path + '.png'
    File.stub(:exist?, proc { |p| p == replacement_path }) do
      bitmap = Cache.normal_bitmap(path)
      assert_equal [640, 480], HRFix::Pictures.original_size(bitmap)
      assert_equal [1280, 960], bitmap.graphics_replace_actual_size
      assert Bitmap.instances.last.disposed?
      assert_same bitmap, Cache.normal_bitmap(path)
      assert_equal 2, Bitmap.loads.size
    end
  end
  def test_replacement_without_original_does_not_guess_fullscreen
    Cache.instance_variable_set(:@cache, {})
    Bitmap.missing_original = true
    File.stub(:exist?, true) do
      bitmap = nil
      capture_io { bitmap = Cache.normal_bitmap('Graphics/Pictures/full') }
      picture = Game_Picture.new
      picture.show('full', 0, 0, 0, 100, 100)
      refute HRFix::Pictures.fullscreen?(picture, bitmap)
    end
  end
end
