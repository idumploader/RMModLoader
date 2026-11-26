require 'minitest/autorun'
module MapUpdateOptimizations
  class << self
    attr_accessor :position,:aura,:autorun,:object_character,:invalidations
    def invalidate_autoruns; self.invalidations = (invalidations || 0) + 1; end
  end
end
module MapRefreshOptimization
  class << self; attr_accessor :enabled; end
  def self.installed?; true; end
end
module MusicReplayOptimization
  class << self; attr_accessor :enabled; end
end
module BattlePortraitCacheFix
  class << self; attr_accessor :enabled, :unavailable; end
  def self.installed?; !unavailable; end
end
module ModLoader
  class << self
    attr_accessor :glyph_enabled
    def glyph_cache_enable(value); self.glyph_enabled = value; true; end
    def glyph_cache_status; '{"enabled":' + glyph_enabled.to_s + '}'; end
  end
  class Section < Hash
    attr_accessor :fail, :commits
    def commit
      raise 'save failed' if fail
      self.commits = (commits || 0) + 1
    end
  end
  def self.nvram; self; end
  def self.section(name); @section ||= Section.new; end
  module ModMenu
    class << self
      attr_accessor :items
      def category(name, options); self.items = []; yield self; end
      def header(label); end
      def toggle(label, options); items << [label, options]; end
    end
  end
end
module SceneManager
  def self.run; :scene_started; end
end
load File.expand_path('../mod_loader/framework/core/optimizations.rb', __dir__)
ModLoader::ModMenu.items = []
ModLoader::Optimizations.register_menu(ModLoader::ModMenu)
class ModLoaderOptimizationsTest < Minitest::Test
  O = ModLoader::Optimizations
  def setup
    O.settings.clear; O.settings.fail = false; O.settings.commits = 0
    BattlePortraitCacheFix.unavailable = false
    O.restore
  end
  def test_menu_controls_all_five_groups
    assert_equal 5, ModLoader::ModMenu.items.size
    ModLoader::ModMenu.items.each do |label, options|
      assert options[:enabled].call
      options[:set].call(false)
      refute options[:get].call
    end
    assert_equal 5, O.settings.commits
    refute MapUpdateOptimizations.object_character
    refute MapUpdateOptimizations.position
  end
  def test_scene_loop_restores_saved_false_values
    O.set(:music_replay, false); O.set(:event_refresh, false)
    O.set(:battle_portraits, false)
    O.set(:glyph_cache, false)
    ModLoader.glyph_cache_enable(true)
    BattlePortraitCacheFix.enabled = true
    MusicReplayOptimization.enabled = MapRefreshOptimization.enabled = true
    assert_equal :scene_started, SceneManager.run
    refute MusicReplayOptimization.enabled
    refute MapRefreshOptimization.enabled
    refute BattlePortraitCacheFix.enabled
    refute ModLoader.glyph_enabled
    assert O.enabled?(:map_updates)
  end
  def test_save_failure_leaves_runtime_and_previous_setting
    O.set(:music_replay, false)
    O.settings.fail = true
    refute O.set(:music_replay, true)
    refute O.enabled?(:music_replay)
    assert_equal false, O.settings[:music_replay]
  end
  def test_invalid_or_missing_settings_default_on_without_writing
    O.settings[:map_updates] = 'false'
    O.restore
    assert O.enabled?(:map_updates)
    assert O.enabled?(:music_replay)
    assert O.enabled?(:glyph_cache)
    assert_equal 0, O.settings.commits
    refute O.set(:unknown, true)
  end
  def test_unavailable_battle_fix_disables_control
    BattlePortraitCacheFix.unavailable = true
    item = ModLoader::ModMenu.items.find { |label, options| options[:id] == :battle_portraits }[1]
    refute item[:enabled].call
    refute item[:get].call
    refute item[:set].call(false)
    assert_equal 0, O.settings.commits
  end
  def test_glyph_control_reads_native_state_and_handles_older_dll
    item = ModLoader::ModMenu.items.find { |label, options| options[:id] == :glyph_cache }[1]
    ModLoader.glyph_cache_enable(false)
    refute item[:get].call
    ModLoader.singleton_class.send(:alias_method, :test_glyph_status, :glyph_cache_status)
    ModLoader.singleton_class.send(:remove_method, :glyph_cache_status)
    refute item[:enabled].call
    refute item[:get].call
    refute item[:set].call(true)
    assert_equal 0, O.settings.commits
  ensure
    if ModLoader.respond_to?(:test_glyph_status)
      ModLoader.singleton_class.send(:alias_method, :glyph_cache_status, :test_glyph_status)
      ModLoader.singleton_class.send(:remove_method, :test_glyph_status)
    end
  end
end
