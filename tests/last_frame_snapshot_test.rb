require 'minitest/autorun'
module ModLoader
  class << self
    attr_accessor :ready, :failure, :last_bitmap, :enabled, :enable_accepted
    def last_frame_enable(value)
      return false if enable_accepted == false
      self.enabled=value
      true
    end
    def last_frame_copy(bitmap)
      self.last_bitmap=bitmap
      raise 'copy failed' if failure
      bitmap.pixels=:previous if ready
      !!ready
    end
  end
end
module ModLoader::Display
  class Settings < Hash
    attr_accessor :commits
    def commit; self.commits=(commits || 0)+1; end
  end
  def self.settings; @settings ||= Settings.new; end
end
class Bitmap
  attr_accessor :pixels, :blurred
  def initialize(*args); @disposed=false; end
  def dispose; @disposed=true; end
  def disposed?; @disposed; end
  def blur; @blurred=pixels; end
end
module Graphics
  def self.width; 640; end
  def self.height; 480; end
  def self.snap_to_bitmap
    Bitmap.new.tap { |b| b.pixels=:current }
  end
end
module SceneManager
  def self.snapshot_for_background
    @background_bitmap.dispose if @background_bitmap
    @background_bitmap=Graphics.snap_to_bitmap
    @background_bitmap.blur
  end
  def self.background_bitmap; @background_bitmap; end
end
load File.expand_path('../mod_loader/framework/renderer/last_frame_snapshot.rb',__dir__)
class LastFrameSnapshotTest < Minitest::Test
  def setup
    ModLoader::Display.settings.delete(:last_frame_menu_background)
    ModLoader.enable_accepted=true
    ModLoader.last_bitmap=nil
    ModLoader::LastFrameSnapshot.restore
    ModLoader.ready=true
    ModLoader.failure=false
  end
  def test_menu_blurs_ready_frame_and_disposes_old_background
    SceneManager.snapshot_for_background
    old=SceneManager.background_bitmap
    assert_equal :previous,old.blurred
    SceneManager.snapshot_for_background
    assert old.disposed?
  end
  def test_toggle_off_uses_original_menu_path_and_saves
    ModLoader::LastFrameSnapshot.enabled=false
    refute ModLoader.enabled
    assert_equal false,ModLoader::Display.settings[:last_frame_menu_background]
    SceneManager.snapshot_for_background
    assert_equal :current,SceneManager.background_bitmap.blurred
    assert_nil ModLoader.last_bitmap
    assert_equal :current,Graphics.last_frame_to_bitmap.pixels
    ModLoader::LastFrameSnapshot.enabled=true
    SceneManager.snapshot_for_background
    assert_equal :previous,SceneManager.background_bitmap.blurred
  end

  def test_saved_off_is_restored_on_script_reload
    ModLoader::LastFrameSnapshot.enabled=false
    ModLoader.enabled=true
    load File.expand_path('../mod_loader/framework/renderer/last_frame_snapshot.rb',__dir__)
    refute ModLoader.enabled
    SceneManager.snapshot_for_background
    assert_equal :current,SceneManager.background_bitmap.blurred
  end

  def test_failed_native_toggle_does_not_save
    ModLoader.enable_accepted=false
    refute ModLoader::LastFrameSnapshot.send(:enabled=,false)
    assert ModLoader::LastFrameSnapshot.enabled?
    assert_nil ModLoader::Display.settings[:last_frame_menu_background]
  end

  def test_ordinary_snapshot_is_current
    assert_equal :current,Graphics.snap_to_bitmap.pixels
  end
  def test_missing_frame_disposes_empty_bitmap_and_falls_back
    ModLoader.ready=false
    SceneManager.snapshot_for_background
    assert_equal :current,SceneManager.background_bitmap.blurred
    assert ModLoader.last_bitmap.disposed?
  end
  def test_exception_disposes_bitmap_and_restores_scope
    ModLoader.failure=true
    assert_raises(RuntimeError) { SceneManager.snapshot_for_background }
    assert ModLoader.last_bitmap.disposed?
    assert_equal :current,Graphics.snap_to_bitmap.pixels
  end
  def test_nested_scope_restores_previous_value
    Graphics.with_last_frame_menu_snapshot do
      Graphics.with_last_frame_menu_snapshot { assert_equal :previous,Graphics.snap_to_bitmap.pixels }
      assert_equal :previous,Graphics.snap_to_bitmap.pixels
    end
    assert_equal :current,Graphics.snap_to_bitmap.pixels
  end
end
