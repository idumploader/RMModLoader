require 'minitest/autorun'

SCRIPTS = File.expand_path(ENV.fetch('BS2_SCRIPTS_DIR', '../../decompile_data/decompile/Scripts'), __dir__)
def original_method(number, name)
  file = Dir[File.join(SCRIPTS, "#{number} - *.rb")].first
  raise "Set BS2_SCRIPTS_DIR to the decompiled BS2 Scripts directory (missing script #{number})" unless file
  lines = File.read(file).lines
  first = lines.index { |line| line.strip =~ /\Adef #{Regexp.escape(name)}(?:\(|\s|$)/ }
  last = (first + 1...lines.size).find { |i| lines[i].strip == 'end' && lines[i] =~ /^  end/ }
  lines[first..last].join
end

class Sprite
  attr_accessor :x, :y, :z, :visible, :opacity
end
class Game_CharacterBase
  def initialize(tile_id, character_name)
    @tile_id = tile_id
    @character_name = character_name
  end
  class_eval original_method(32, 'object_character?'), '{0032}'
end
class Sprite_Character < Sprite
  attr_reader :animation_delta
  def initialize(character)
    @character = character
    self.x, self.y, self.z = 3, 4, 0
  end
  class_eval original_method(43, 'update_position'), '{0043}'
  alias vxace_sp1_update_position update_position
  class_eval original_method(123, 'update_position'), '{0123}'
  def move_animation(dx, dy); @animation_delta = [dx, dy]; end
end
class Sprite
  class_eval original_method(203, 'star_aura_effect_initialize')
  class_eval original_method(203, 'dispose_star_aura_effects')
  class_eval original_method(203, 'star_aura_effects_update')
end
module StarAuraEffect
  P = { 0 => { :end => 60, :pattern => {} } }
end
class AuraTarget
  attr_accessor :star_aura_effect_update, :effects, :data, :updates
  def initialize
    @star_aura_effect_update = true
    @effects, @data, @updates = [], [], 0
  end
  def star_aura_effect; @effects; end
  def aura_effect_data; @data; end
  def update_aura_effect(sprite); @updates += 1; end
  def aura_effect_data_delete_opacity_zero; @data.delete_if { |h| h[:opacity] == 0 }; end
end
class Sprite_StarAuraEffect
  attr_reader :opacity
  def initialize(*args); @opacity = 255; @disposed = false; end
  def update_by_effect_hash(data); @opacity = data[:opacity]; end
  def dispose; @disposed = true; end
  def disposed?; @disposed; end
end
module RPG
  class CommonEvent
    attr_accessor :trigger, :switch_id, :list
    attr_reader :checks
    def initialize(trigger, switch, list)
      @trigger, @switch_id, @list, @checks = trigger, switch, list, 0
    end
    def autorun?; @checks += 1; @trigger == 1; end
  end
end
class Game_Map
  attr_reader :interpreter
  def initialize
    @interpreter = Object.new
    def @interpreter.setup(list); (@calls ||= []) << list; end
    def @interpreter.calls; @calls || []; end
  end
  class_eval original_method(30, 'setup_autorun_common_event')
end

load File.expand_path('../mod_loader/scripts/1100 - MapUpdateOptimizations.rb', __dir__)
# A later wrapper must still run.
class Sprite_Character
  alias test_later_position update_position
  attr_reader :nickname_position
  def update_position
    test_later_position
    @nickname_position = [x - 20, y - 32]
  end
end

class MapUpdateOptimizationsTest < Minitest::Test
  def setup
    MapUpdateOptimizations.position = MapUpdateOptimizations.aura = MapUpdateOptimizations.autorun = true
    MapUpdateOptimizations.object_character = true
    MapUpdateOptimizations.invalidate_autoruns
    $game_switches = Hash.new(false)
    $data_common_events = []
  end
  def character
    c = Object.new
    def c.calls; @calls ||= Hash.new(0); end
    def c.screen_x; calls[:x] += 1; -17; end
    def c.screen_y; calls[:y] += 1; 121; end
    def c.screen_z; calls[:z] += 1; 200; end
    c
  end
  def aura
    sprite = Sprite.new
    sprite.x, sprite.y, sprite.visible, sprite.opacity = 1, 2, true, 255
    sprite.star_aura_effect_initialize
    [sprite, AuraTarget.new]
  end
  def test_coordinates_and_animation_match_original_and_preserve_later_wrapper
    c = character
    sprite = Sprite_Character.new(c)
    sprite.update_position
    assert MapUpdateOptimizations.position_installed
    assert_equal({ :x => 1, :y => 1, :z => 1 }, c.calls)
    assert_equal [-17, 121, 200], [sprite.x, sprite.y, sprite.z]
    assert_equal [-20, 117], sprite.animation_delta
    assert_equal [-37, 89], sprite.nickname_position
    MapUpdateOptimizations.position = false
    old = Sprite_Character.new(character)
    old.update_position
    assert_equal [old.x, old.y, old.z, old.animation_delta], [sprite.x, sprite.y, sprite.z, sprite.animation_delta]
  end
  def test_object_character_matches_stock_with_optimization_on_or_off
    assert MapUpdateOptimizations.object_character_installed
    cases = [[0, '', false], [0, '!Door', true], [0, 'Door', false], [1, 'Door', true]]
    [true, false].each do |enabled|
      MapUpdateOptimizations.object_character = enabled
      cases.each do |tile_id, name, expected|
        assert_equal expected, Game_CharacterBase.new(tile_id, name).object_character?
      end
    end
  end
  def test_empty_aura_skips_only_after_initialization_and_wakes_on_change
    sprite, target = aura
    sprite.star_aura_effects_update(target)
    assert_equal 1, target.updates
    5.times { sprite.star_aura_effects_update(target) }
    assert_equal 1, target.updates
    target.effects = [0]
    target.star_aura_effect_update = true
    sprite.star_aura_effects_update(target)
    sprite.star_aura_effects_update(target)
    assert_equal 3, target.updates
    target.effects = []
    target.star_aura_effect_update = true
    sprite.star_aura_effects_update(target)
    sprite.star_aura_effects_update(target)
    assert_equal 4, target.updates
  end
  def test_existing_effects_finish_after_aura_is_removed
    sprite, target = aura
    target.data << { :opacity => 255 }
    sprite.star_aura_effects_update(target)
    effect = sprite.instance_variable_get(:@star_aura_effect_sprites).first
    target.data.first[:opacity] = 0
    sprite.star_aura_effects_update(target)
    assert effect.disposed?
    assert_empty target.data
    assert_empty sprite.instance_variable_get(:@star_aura_effect_sprites)
    sprite.star_aura_effects_update(target)
    assert_equal 2, target.updates
  end
  def test_nil_target_cleanup_and_disabled_aura_use_original
    sprite, target = aura
    sprite.star_aura_effects_update(target)
    MapUpdateOptimizations.aura = false
    sprite.star_aura_effects_update(target)
    assert_equal 2, target.updates
    sprite.star_aura_effects_update(nil)
    assert_nil sprite.instance_variable_get(:@star_aura_last_x)
    assert_equal true, sprite.instance_variable_get(:@star_aura_effect_update)
  end
  def event(trigger, switch, name)
    RPG::CommonEvent.new(trigger, switch, [name])
  end
  def test_autorun_order_switch_changes_repeated_runs_and_no_match
    first, second, parallel = event(1, 1, :a), event(1, 2, :b), event(2, 1, :parallel)
    $data_common_events = [nil, parallel, first, second]
    map = Game_Map.new
    assert_nil map.setup_autorun_common_event
    $game_switches[2] = true
    assert_same second, map.setup_autorun_common_event
    $game_switches[1] = true
    2.times { assert_same first, map.setup_autorun_common_event }
    assert_equal [[:b], [:a], [:a]], map.interpreter.calls
    assert_equal [1, 1, 1], [first.checks, second.checks, parallel.checks]
    $game_switches[1] = $game_switches[2] = false
    assert_nil map.setup_autorun_common_event
  end
  def test_autorun_cache_handles_database_replacement_growth_and_trigger_changes
    a = event(0, 1, :a)
    $data_common_events = [nil, a]
    $game_switches[1] = true
    map = Game_Map.new
    assert_nil map.setup_autorun_common_event
    a.trigger = 1
    assert_same a, map.setup_autorun_common_event
    a.trigger = 0
    assert_nil map.setup_autorun_common_event
    b = event(1, 1, :b)
    $data_common_events << b
    assert_same b, map.setup_autorun_common_event
    c = event(1, 1, :c)
    $data_common_events = [nil, c]
    assert_same c, map.setup_autorun_common_event
    $data_common_events[1] = b
    MapUpdateOptimizations.invalidate_autoruns
    assert_same b, map.setup_autorun_common_event
  end
  def test_disabled_autorun_uses_original_and_new_switch_state_after_load
    a, b = event(1, 1, :a), event(1, 2, :b)
    $data_common_events = [nil, a, b]
    $game_switches[1] = true
    map = Game_Map.new
    assert_same a, map.setup_autorun_common_event
    $game_switches = { 2 => true }
    assert_same b, map.setup_autorun_common_event
    MapUpdateOptimizations.autorun = false
    assert_same b, map.setup_autorun_common_event
    assert_operator a.checks, :>, 1
  end
end
