require 'minitest/autorun'
module Graphics
  class << self; attr_accessor :width, :height; end
  self.width = 1400; self.height = 800
end
Rect = Struct.new(:x, :y, :width, :height)
class Bitmap
  attr_reader :width, :height, :draws
  def initialize(w, h); @width=w; @height=h; @draws=[]; end
  def disposed?; !!@disposed; end
  def dispose; @disposed=true; end
  def rect; Rect.new(0,0,width,height); end
  def stretch_blt(*args); @draws << [:stretch, args]; end
  def clear_rect(*args); @draws << [:clear, args]; end
end
module Cache
  def self.face(name); (@faces ||= {})[name] ||= Bitmap.new(384,192); end
  def self.clear
    (@faces || {}).each_value(&:dispose)
    @faces={}
  end
end
module SceneManager
  def self.run; yield if block_given?; :ran; end
end
load File.expand_path('../mod_loader/scripts/453 - BSFaceSheet.rb', __dir__)
load File.expand_path('../mod_loader/scripts/454 - BSHudBitmapCache.rb', __dir__)

class BSHudBitmapCacheTest < Minitest::Test
  def setup
    Graphics.width=1400; Graphics.height=800
    Cache.clear
  end
  def portrait(name='Actor', index=0, size=80)
    BSHudBitmapCache.portrait(name,index,size) { |bitmap| bitmap }
  end
  def test_reuse_and_face_changes
    first=portrait
    assert_same first, portrait
    refute_same first, portrait('Actor',1)
    refute_same first, portrait('Other')
    refute_same first, portrait('Actor',0,81)
    assert_equal 1, first.draws.count { |draw| draw[0]==:stretch }
    refute Cache.face('Actor').disposed?
  end
  def test_blank_portrait_is_reused_without_loading_source
    Cache.singleton_class.send(:alias_method,:saved_face,:face)
    Cache.singleton_class.send(:define_method,:face) { |_| raise 'unexpected source load' }
    first=portrait('')
    assert_same first, portrait('')
    assert_empty first.draws
  ensure
    Cache.singleton_class.send(:alias_method,:face,:saved_face)
  end
  def test_source_replacement_disposal_and_output_disposal
    first=portrait
    Cache.face('Actor').dispose
    Cache.instance_variable_get(:@faces)['Actor']=Bitmap.new(384,192)
    refute_same first, second=portrait
    assert first.disposed?
    second.dispose
    refute_same second, portrait
  end
  def test_resolution_and_cache_clear_release_only_owned_images
    first=portrait
    source=Cache.face('Actor')
    Graphics.width=1920
    refute_same first, second=portrait
    assert first.disposed?
    refute source.disposed?
    Cache.clear
    assert second.disposed?
    assert_equal 0, BSHudBitmapCache.status[:bytes]
  end
  def test_lru_entry_bound
    first=portrait('Actor',0,1)
    second=portrait('Actor',1,1)
    assert_same first, portrait('Actor',0,1)
    63.times { |i| portrait('Actor',i+2,1) }
    assert second.disposed?
    refute first.disposed?
    assert_equal 64, BSHudBitmapCache.status[:entries]
  end
  def test_byte_bound_and_oversized_temporary_even_on_exception
    source=Cache.face('Actor')
    owned=[]
    3.times do |i|
      BSHudBitmapCache.borrow([i],source,1024,1024,lambda { |_| }) { |b| owned << b }
    end
    assert owned[0].disposed?
    assert_equal 8*1024*1024, BSHudBitmapCache.status[:bytes]
    temp=nil
    assert_raises(RuntimeError) do
      BSHudBitmapCache.borrow([:large],source,2048,2048,lambda { |_| }) do |b|
        temp=b
        raise 'consumer failed'
      end
    end
    assert temp.disposed?
    refute source.disposed?
    assert_equal 2, BSHudBitmapCache.status[:entries]
  end
  def test_failed_builder_releases_partial_bitmap_and_can_retry
    source=Cache.face('Actor'); partial=nil
    assert_raises(RuntimeError) do
      BSHudBitmapCache.borrow([:fail],source,2,2,lambda { |b| partial=b; raise 'build failed' }) { |_| }
    end
    assert partial.disposed?
    assert_equal 0, BSHudBitmapCache.status[:entries]
    BSHudBitmapCache.borrow([:fail],source,2,2,lambda { |_| }) { |b| refute b.disposed? }
  end
  def test_scene_restart_releases_derived_images
    first=portrait
    assert_equal :ran, SceneManager.run
    assert first.disposed?
    assert_equal 0, BSHudBitmapCache.status[:entries]
  end
end
