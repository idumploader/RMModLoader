require 'minitest/autorun'
load File.expand_path('../mod_loader/framework/core/lifecycle.rb', __dir__)

class ModLoaderLifecycleTest < Minitest::Test
  L = ModLoader::Lifecycle
  def setup
    @saved = L.instance_variable_get(:@callbacks)
    L.instance_variable_set(:@callbacks, nil)
    @calls = []
  end
  def teardown
    L.instance_variable_set(:@callbacks, @saved)
  end
  def test_order_and_keyed_replacement_survive_repeated_runs
    L.register(:before_run, :late, 20) { @calls << :late }
    L.register(:before_run, :early, 10) { @calls << :obsolete }
    L.register(:before_run, :early, 10) { @calls << :early }
    2.times { L.before_run }
    assert_equal [:early, :late, :early, :late], @calls
  end
  def test_cleanup_finishes_other_callbacks_then_raises_original_failure
    failure = RuntimeError.new('first cleanup failed')
    L.register(:cleanup, :first, 10) { @calls << :first; raise failure }
    L.register(:cleanup, :second, 20) { @calls << :second; raise 'second failed' }
    L.register(:cleanup, :last, 30) { @calls << :last }
    assert_same failure, assert_raises(RuntimeError) { L.cleanup }
    assert_equal [:first, :second, :last], @calls
  end
  def test_cleanup_runs_when_before_run_raises
    L.register(:before_run, :broken) { raise 'startup failed' }
    L.register(:cleanup, :release) { @calls << :released }
    assert_raises(RuntimeError) do
      begin
        L.before_run
      ensure
        L.cleanup
      end
    end
    assert_equal [:released], @calls
  end
end
