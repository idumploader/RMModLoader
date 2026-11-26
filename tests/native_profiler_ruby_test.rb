require 'minitest/autorun'

module ModLoader
  class << self
    attr_accessor :running, :full, :saved, :frames, :stops, :discarded
    def profiler_start(limit)
      raise ArgumentError unless limit.is_a?(Integer) && limit >= 1024
      self.running = true
      self.frames = 0
    end
    def profiler_recording?; !!running; end
    def profiler_stop; self.running = false; self.stops += 1; end
    def profiler_frame
      self.frames += 1
      self.running = false if full
      running
    end
    def profiler_save(path); self.saved << path; end
    def profiler_discard; self.discarded = true; end
  end
end
module Graphics
  class << self
    attr_accessor :calls, :failure
    def update
      self.calls += 1
      raise failure if failure
      :updated
    end
  end
end
module SceneManager
  class << self
    attr_accessor :failure
    def run; raise failure if failure; end
  end
end
class FakeRGSSReset < Exception; end

load File.expand_path('../mod_loader/framework/diagnostics/native_profiler.rb', __dir__)

class NativeProfilerRubyTest < Minitest::Test
  P = ModLoader::Profiler
  def setup
    ModLoader.stops ||= 0
    P.discard
    ModLoader.saved = []
    ModLoader.full = false
    ModLoader.discarded = false
    Graphics.calls = 0
    Graphics.failure = SceneManager.failure = nil
    @original = Graphics.method(:update)
  end
  def teardown
    P.discard
    (class << Graphics; self; end).send(:define_method, :update, @original)
  end
  def test_disabled_does_not_install_frame_wrapper_or_save
    Graphics.update
    assert_equal @original, Graphics.method(:update)
    refute P.recording?
    assert_empty ModLoader.saved
  end
  def test_frame_limited_recording_stops_saves_and_restores_graphics
    P.start('profile-test.json', :frames => 2)
    assert_equal :updated, Graphics.update
    assert P.recording?
    Graphics.update
    refute P.recording?
    assert_equal ['profile-test.json'], ModLoader.saved
    assert_equal @original, Graphics.method(:update)
    Graphics.update
    assert_equal 2, ModLoader.frames
  end
  def test_full_buffer_stops_at_safe_frame_boundary
    P.start('profile-limit.json')
    ModLoader.full = true
    Graphics.update
    refute P.recording?
    assert_equal ['profile-limit.json'], ModLoader.saved
    assert_equal @original, Graphics.method(:update)
  end
  def test_memory_only_and_explicit_save
    P.start
    P.stop
    assert_empty ModLoader.saved
    assert_equal 'later.json', P.save('later.json')
    assert_equal ['later.json'], ModLoader.saved
  end
  def test_bad_start_does_not_wrap_graphics
    assert_raises(ArgumentError) { P.start(nil, :frames => 0) }
    assert_raises(ArgumentError) { P.start(nil, :max_events => 'bad') }
    refute P.recording?
    assert_equal @original, Graphics.method(:update)
  end
  def test_repeated_start_is_rejected_without_losing_recording
    P.start('first.json')
    assert_raises(RuntimeError) { P.start('second.json') }
    P.stop
    assert_equal ['first.json'], ModLoader.saved
  end
  def test_f12_in_graphics_or_scene_stops_without_file_io
    [Graphics, SceneManager].each do |target|
      P.start('reset.json')
      target.failure = FakeRGSSReset.new
      assert_raises(FakeRGSSReset) { target == Graphics ? Graphics.update : SceneManager.run }
      target.failure = nil
      refute P.recording?
      assert_empty ModLoader.saved
      assert_equal @original, Graphics.method(:update)
    end
  end
  def test_block_preserves_result_and_exception
    assert_equal 42, P.record('block.json') { 42 }
    assert_equal ['block.json'], ModLoader.saved
    assert_raises(ZeroDivisionError) { P.record('error.json') { 1 / 0 } }
    assert_equal ['block.json'], ModLoader.saved
    refute P.recording?
  end
  def test_later_mod_wrapper_is_preserved_and_restart_does_not_double_tick
    P.start
    previous = Graphics.method(:update)
    (class << Graphics; self; end).send(:define_method, :update) { previous.call }
    later = Graphics.method(:update)
    P.stop
    assert_equal later, Graphics.method(:update)
    P.start(nil, :frames => 2)
    Graphics.update
    assert P.recording?
    assert_equal 1, ModLoader.frames
    Graphics.update
    refute P.recording?
    assert_equal 2, ModLoader.frames
    assert_equal later, Graphics.method(:update)
  end
end
