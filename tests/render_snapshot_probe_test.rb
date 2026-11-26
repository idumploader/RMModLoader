require 'minitest/autorun'

class Viewport
  attr_accessor :disposed
  def disposed?; !!disposed; end
end
class Bitmap < Viewport; end
class SnapshotBitmapSubclass < Bitmap; end

module Graphics
  def self.update; :original; end
end
module ModLoader
  # Native loader namespaces must not shadow the top-level RGSS classes.
  module Viewport; end
  module Bitmap; end
  class << self
    attr_accessor :snapshot, :capture_failure, :calls
    def parallel_renderer_capture(viewport)
      calls << [:capture, viewport]
      self.snapshot = !capture_failure
    end
    def parallel_renderer_draw(bitmap)
      calls << [:draw, bitmap]
      !!snapshot
    end
    def parallel_renderer_reference(viewport, bitmap)
      calls << [:reference, viewport, bitmap]
      true
    end
    def parallel_renderer_clear
      calls << [:clear]
      self.snapshot = false
      true
    end
    def parallel_renderer_status; '{"error":"unsupported node"}'; end
    def parallel_renderer_start(bitmap, repeats)
      calls << [:start, bitmap, repeats]
      !!snapshot
    end
    def parallel_renderer_collect(bitmap)
      calls << [:collect, bitmap]
      !!snapshot
    end
    def parallel_renderer_submit(viewport, bitmap, repeats)
      calls << [:submit, viewport, bitmap, repeats]
      true
    end
    def parallel_renderer_optimization(mode)
      calls << [:optimization, mode]
      true
    end
    def parallel_renderer_invalidate(bitmap)
      calls << [:invalidate, bitmap]
      true
    end
  end
end

script = File.expand_path('../mod_loader/framework/renderer/parallel_renderer.rb', __dir__)
original_update = Graphics.method(:update)
load script
raise 'probe installed an unsolicited frame hook' unless original_update == Graphics.method(:update)
load File.expand_path('render_snapshot_rgss_smoke.rb', __dir__)

class ParallelRendererTest < Minitest::Test
  P = ModLoader::ParallelRenderer
  def setup
    ModLoader.calls = []
    ModLoader.snapshot = ModLoader.capture_failure = false
  end
  def test_can_replay_after_original_is_disposed
    viewport, target = Viewport.new, Bitmap.new
    P.capture(viewport)
    viewport.disposed = true
    assert P.draw(target)
    assert_equal [:draw, target], ModLoader.calls.last
  end
  def test_optimization_and_invalidation_validate_before_native_access
    [-1, 3, 1.5, nil].each { |mode| assert_raises(ArgumentError) { P.optimization(mode) } }
    assert_empty ModLoader.calls
    assert P.optimization(2)
    bitmap = Bitmap.new
    assert P.invalidate(bitmap)
    bitmap.disposed = true
    assert_raises(ArgumentError) { P.invalidate(bitmap) }
    assert_equal [[:optimization, 2], [:invalidate, bitmap]], ModLoader.calls
  end
  def test_bad_capture_discards_previous_snapshot
    P.capture(Viewport.new)
    assert_raises(ArgumentError) { P.capture(Object.new) }
    refute ModLoader.snapshot
    assert_raises(RuntimeError) { P.draw(Bitmap.new) }
  end
  def test_disposed_objects_are_rejected_before_native_access
    target = Bitmap.new
    target.disposed = true
    assert_raises(ArgumentError) { P.draw(target) }
    viewport = Viewport.new
    viewport.disposed = true
    assert_raises(ArgumentError) { P.capture(viewport) }
    assert_equal [[:clear]], ModLoader.calls
  end
  def test_native_capture_failure_reports_reason_and_leaves_no_snapshot
    P.capture(Viewport.new)
    ModLoader.capture_failure = true
    error = assert_raises(RuntimeError) { P.capture(Viewport.new) }
    assert_match(/unsupported node/, error.message)
    refute ModLoader.snapshot
  end
  def test_clear_releases_snapshot_and_subclasses_are_explicitly_rejected
    P.capture(Viewport.new)
    P.clear
    refute ModLoader.snapshot
    assert_raises(ArgumentError) { P.draw(SnapshotBitmapSubclass.new) }
  end
  def test_reference_does_not_replace_snapshot
    P.capture(Viewport.new)
    assert P.reference(Viewport.new, Bitmap.new)
    assert ModLoader.snapshot
  end
  def test_uses_rgss_classes_despite_modloader_namespaces
    viewport, bitmap = ::Viewport.new, ::Bitmap.new
    assert P.capture(viewport)
    assert P.reference(viewport, bitmap)
    assert P.draw(bitmap)
    assert_equal [[:clear], [:capture, viewport], [:reference, viewport, bitmap], [:draw, bitmap]], ModLoader.calls
  end
  def test_reference_accepts_rgb_written_with_unchanged_zero_alpha
    output, = capture_io do
      assert RenderSnapshotSmoke.verify_reference(:plain, [[0, 0, 0, 0]], [[230, 40, 70, 0]])
    end
    assert_match(/RGB=1, alpha=0/, output)
  end
  def test_reference_rejects_no_drawing_even_on_an_opaque_background
    capture_io do
      error = assert_raises(RuntimeError) do
        RenderSnapshotSmoke.verify_reference(:plain, [[20, 30, 40, 255]], [[20, 30, 40, 255]])
      end
      assert_match(/changed no pixel channels/, error.message)
    end
  end
  def test_empty_reference_must_preserve_every_channel
    capture_io do
      assert RenderSnapshotSmoke.verify_reference(:empty, [[0, 0, 0, 0]], [[0, 0, 0, 0]])
      assert_raises(RuntimeError) do
        RenderSnapshotSmoke.verify_reference(:empty, [[0, 0, 0, 0]], [[1, 0, 0, 0]])
      end
    end
  end
  def test_all_worker_entrypoints_keep_the_repeats_error_contract
    target, viewport = Bitmap.new, Viewport.new
    calls = [proc { |n| P.start(target, n) },
             proc { |n| P.submit_frame(target, n) },
             proc { |n| P.submit(viewport, target, n) }]
    calls.each do |call|
      [0, 10001, 1.5].each do |value|
        error = assert_raises(ArgumentError) { call.call(value) }
        assert_equal 'Expected Integer repeats in 1..10000', error.message
      end
    end
    assert_empty ModLoader.calls
  end

  def test_worker_rejects_invalid_arguments_before_native_access
    target = Bitmap.new
    [0, -1, 10001, 1.5, '2'].each { |n| assert_raises(ArgumentError) { P.start(target, n) } }
    target.disposed = true
    assert_raises(ArgumentError) { P.start(target) }
    assert_raises(ArgumentError) { P.collect(target) }
    assert_raises(ArgumentError) { P.collect(SnapshotBitmapSubclass.new) }
    assert_empty ModLoader.calls
  end
  def test_worker_submission_collection_and_native_failure
    target = Bitmap.new
    assert_raises(RuntimeError) { P.start(target) }
    P.capture(Viewport.new)
    assert P.start(target, 25)
    assert_equal [:start, target, 25], ModLoader.calls.last
    assert P.collect(target)
    assert_equal [:collect, target], ModLoader.calls.last
  end
  def test_submit_does_not_clear_pending_frames_and_validates_before_native_access
    vp, bitmap = Viewport.new, Bitmap.new
    assert P.submit(vp, bitmap, 2)
    assert_equal [[:submit, vp, bitmap, 2]], ModLoader.calls
    assert_raises(ArgumentError) { P.submit(vp, bitmap, 0) }
    assert_raises(ArgumentError) { P.submit(Object.new, bitmap) }
    bitmap.disposed = true
    assert_raises(ArgumentError) { P.submit(vp, bitmap) }
    assert_equal 1, ModLoader.calls.size
  end
end
