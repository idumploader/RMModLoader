require 'minitest/autorun'

# Stock notifier plus the WdTk static-ID setter, as installed by this game.
[['Game_Switches', 13, false], ['Game_Variables', 14, 0]].each do |name, number, default|
  Object.class_eval <<-RUBY, '{%04d}' % number, 1
    class #{name}
      attr_reader :data
      def initialize; @data = []; end
      def [](id); @data[id] || #{default.inspect}; end
      def on_change; $game_map.need_refresh = true; end
    end
  RUBY
  Object.const_get(name).class_eval <<-RUBY, '{0132}', 1
    def []=(id, value)
      @data[id] = value
      on_change unless id == 99
    end
  RUBY
end

# Minimal optional dependencies for loading the combined map script.
class Game_CharacterBase
  def object_character?; false; end
end
class Sprite; end
class Sprite_Character < Sprite; end
class Game_Map
  def setup_autorun_common_event; nil; end
end
module RPG
  class CommonEvent
    attr_accessor :trigger
  end
end
load File.expand_path('../mod_loader/scripts/1100 - MapUpdateOptimizations.rb', __dir__)

# A later mod's write observer must receive even unchanged values.
[Game_Switches, Game_Variables].each do |klass|
  klass.class_eval do
    alias observed_original_set []=
    attr_reader :writes
    def []=(id, value)
      result = observed_original_set(id, value)
      (@writes ||= []) << [id, value]
      result
    end
  end
end

class MapRefreshOptimizationTest < Minitest::Test
  def setup
    $game_map = Struct.new(:need_refresh).new(false)
    MapRefreshOptimization.enabled = true
    @switches, @variables = Game_Switches.new, Game_Variables.new
  end

  def test_repeated_writes_preserve_observers_but_changed_values_refresh
    [[@switches, false, true], [@variables, 80, 81]].each do |store, value, changed|
      store[4] = value
      $game_map.need_refresh = false
      assert_equal true, store.send(:[]=, 4, value)
      refute $game_map.need_refresh
      assert_equal [[4, value], [4, value]], store.writes
      assert_equal value, store.data[4]
      store[4] = changed
      assert $game_map.need_refresh
    end
  end

  def test_numeric_type_change_still_refreshes
    @variables[53] = 1
    $game_map.need_refresh = false
    @variables[53] = 1.0
    assert $game_map.need_refresh
    assert_instance_of Float, @variables[53]
  end

  def test_mutable_value_still_refreshes_even_when_same_object
    [[], 'text'].each do |value|
      @variables[53] = value
      value << (value.is_a?(Array) ? 2 : '!')
      $game_map.need_refresh = false
      @variables[53] = value
      assert $game_map.need_refresh
      assert_same value, @variables.data[53]
    end
  end

  def test_explicit_change_and_pending_refresh_are_preserved
    @variables[53] = 80
    @variables[53] = 80
    assert $game_map.need_refresh
    $game_map.need_refresh = false
    @variables.on_change
    assert $game_map.need_refresh
    refute @variables.instance_variable_defined?(:@map_refresh_unchanged_write)
  end

  def test_static_ids_and_rollback
    @switches[99] = true
    refute $game_map.need_refresh
    @variables[53] = 80
    $game_map.need_refresh = false
    MapRefreshOptimization.enabled = false
    @variables[53] = 80
    assert $game_map.need_refresh
  end

  def test_context_is_removed_when_setter_raises
    @variables[53] = 80
    data = @variables.data
    def data.[]=(*args); raise 'write failed'; end
    assert_raises(RuntimeError) { @variables[53] = 80 }
    refute @variables.instance_variable_defined?(:@map_refresh_unchanged_write)
    $game_map.need_refresh = false
    @variables.on_change
    assert $game_map.need_refresh
  end
end
