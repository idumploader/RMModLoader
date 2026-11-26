require 'minitest/autorun'
Rect = Struct.new(:x, :y, :width, :height)
class Bitmap
  attr_reader :draws
  def width; 384; end
  def height; 192; end
  def initialize; @draws = []; @disposed = false; end
  def dispose; @disposed = true; end
  def disposed?; @disposed; end
  def blt(x, y, bitmap, rect)
    raise 'Drawing disposed bitmap' if bitmap.disposed?
    @draws << [x, y, bitmap, rect]
  end
end
class Window
  attr_reader :contents
  def initialize; @contents = Bitmap.new; end
end
module Cache
  def self.face(name)
    @faces ||= {}
    bitmap = @faces[name]
    if !bitmap || bitmap.disposed?
      @loads = (@loads || 0) + 1
      @faces[name] = Bitmap.new
    else
      bitmap
    end
  end
  def self.clear
    (@faces || {}).each_value { |bitmap| bitmap.dispose }
    @faces = {}
  end
  def self.loads; @loads || 0; end
end
# Load the original crop constants and drawing method, then apply the mod.
original = File.expand_path('../../decompile_data/decompile/Scripts/182 - 战斗时头像.rb', __dir__)
if File.exist?(original)
  source = File.read(original).split('class Window_BattleStatus', 2).first
  eval(source, TOPLEVEL_BINDING, original)
else
  # Standalone fixture for the game's shared-cache disposal behavior.
  module ED
    BTL_FACE_RECT_X = 12
    BTL_FACE_RECT_Y = 8
    BTL_FACE_RECT_WIDTH = 72
    BTL_FACE_RECT_HEIGHT = 80
  end
  class Window_Base < Window
    def draw_battle_face(face_name, face_index, x, y, size = 96)
      bitmap = Cache.face(face_name)
      rect = Rect.new(face_index % 4 * 96 + ED::BTL_FACE_RECT_X,
                      face_index / 4 * 96 + ED::BTL_FACE_RECT_Y,
                      ED::BTL_FACE_RECT_WIDTH, ED::BTL_FACE_RECT_HEIGHT)
      contents.blt(x, y, bitmap, rect)
      bitmap.dispose
    end
  end
end
load File.expand_path('../mod_loader/scripts/453 - BSFaceSheet.rb', __dir__)
load File.expand_path('../mod_loader/scripts/1110 - BattlePortraitCacheFix.rb', __dir__)

class BattlePortraitCacheTest < Minitest::Test
  def setup
    Cache.clear
    BattlePortraitCacheFix.enabled = true
    @window = Window_Base.new
  end

  def test_repeated_draws_share_live_cached_bitmap
    before = Cache.loads
    100.times { @window.draw_battle_face('Actor', 5, 4, 20) }
    assert_equal 1, Cache.loads - before
    bitmap = Cache.face('Actor')
    refute bitmap.disposed?
    assert @window.contents.draws.all? { |draw| draw[2].equal?(bitmap) }
  end

  def test_crop_and_destination_remain_unchanged
    @window.draw_battle_face('Actor', 6, 4, 72, 48)
    x, y, bitmap, rect = @window.contents.draws.last
    assert_equal [4, 72], [x, y]
    assert_equal [192 + ED::BTL_FACE_RECT_X, 96 + ED::BTL_FACE_RECT_Y,
                  ED::BTL_FACE_RECT_WIDTH, ED::BTL_FACE_RECT_HEIGHT], rect.to_a
  end

  def test_cache_can_release_and_reload_the_image
    @window.draw_battle_face('Actor', 0, 0, 0)
    old = Cache.face('Actor')
    Cache.clear
    assert old.disposed?
    @window.draw_battle_face('Actor', 0, 0, 0)
    refute_same old, Cache.face('Actor')
    refute Cache.face('Actor').disposed?
  end
  def test_toggle_restores_original_disposal_and_can_resume_caching
    assert BattlePortraitCacheFix.installed?
    BattlePortraitCacheFix.enabled = false
    before = Cache.loads
    3.times { @window.draw_battle_face('Actor', 0, 0, 0) }
    assert_equal 3, Cache.loads - before
    assert @window.contents.draws.last[2].disposed?
    BattlePortraitCacheFix.enabled = true
    before = Cache.loads
    3.times { @window.draw_battle_face('Actor', 0, 0, 0) }
    assert_equal 1, Cache.loads - before
    refute @window.contents.draws.last[2].disposed?
  end
end
