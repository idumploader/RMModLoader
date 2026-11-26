require 'minitest/autorun'
module Graphics
  def self.snap_to_bitmap; :snapshot; end
end
class Bitmap
  def blur; :blur; end
end
class Scene_Base
  def start; [:base]; end
end
class Scene_Title < Scene_Base
  def command_continue(value = :loaded); value; end
  def start; super + [:title]; end
end
module SceneManager
  def self.scene; @scene ||= Scene_Title.new; end
  def self.snapshot_for_background; Graphics.snap_to_bitmap; end
end
load File.expand_path('../../.tools/live-menu-timing.rb',__dir__)
class MenuTimingProbeTest < Minitest::Test
  def setup
    CodexMenuTiming.instance_variable_set(:@active,true)
    CodexMenuTiming.instance_variable_set(:@rows,[])
  end
  def test_cached_handler_survives_method_replacement_and_stop
    scene=Scene_Title.new
    handler=scene.method(:command_continue)
    # A window retains the old Method object while methods are replaced.
    CodexMenuTiming.wrap(Scene_Title,:command_continue,'Scene_Title#command_continue_again')
    assert_equal :loaded,handler.call
    CodexMenuTiming.stop
    assert_equal :loaded,handler.call
    assert_equal :other,scene.command_continue(:other)
  end
  def test_inheritance_and_super_preserve_results_and_nested_accounting
    assert_equal [:base,:title],Scene_Title.new.start
    rows=CodexMenuTiming.dump[:rows]
    assert_equal 2,rows.size
    assert_equal rows.last[:id],rows.first[:parent]
    assert_operator rows.last[:own_ms],:>=,0
  end
  def test_original_exception_is_preserved
    klass=Class.new { def fail_test; raise ArgumentError,'original failure'; end }
    CodexMenuTiming.wrap(klass,:fail_test,'Fail#fail_test')
    error=assert_raises(ArgumentError) { klass.new.fail_test }
    assert_equal 'original failure',error.message
  end
  def test_scope_only_helpers_skip_normal_updates_and_keep_receiver_class
    klass=Class.new { def helper; :ok; end }
    CodexMenuTiming.wrap(klass,:helper,'Helper#helper',true)
    assert_equal :ok,klass.new.helper
    assert_empty CodexMenuTiming.dump[:rows]
    CodexMenuTiming.measure('Scene_Map#create_all_windows') { klass.new.helper }
    rows=CodexMenuTiming.dump[:rows]
    assert_equal 2,rows.size
    assert_equal rows.last[:id],rows.first[:parent]
    assert_equal klass.to_s,rows.first[:receiver_class]
  end
  def test_private_constructor_remains_private_and_preserves_arguments
    klass=Class.new do
      attr_reader :value
      def initialize(value); @value=value; end
    end
    CodexMenuTiming.wrap(klass,:initialize,'Constructor#initialize',true)
    assert klass.private_method_defined?(:initialize)
    object=CodexMenuTiming.measure('Scene_Map#start') { klass.new(73) }
    assert_equal 73,object.value
  end
end
