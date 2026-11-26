require_relative 'support/modmenu_rgss'

module ModLoader
  class << self
    attr_accessor :display_calls, :display_accepted, :render_accepted, :render_active, :render_pending, :hrfix_on
    attr_accessor :snapshot_mode, :snapshot_calls, :snapshot_ready, :cache_accepted, :snapshot_error, :snapshot_limit, :snapshot_limit_accepted
    attr_accessor :filter_mode, :filter_accepted
    attr_accessor :render_threads, :parallel_stretch, :direct_output, :render_options_accepted
    def parallel_renderer_workers; @render_threads || 1; end
    def parallel_renderer_parallel_stretch; !!@parallel_stretch; end
    def parallel_renderer_direct_output; !!@direct_output; end
    def parallel_renderer_set_workers(value)
      return false if @render_options_accepted == false
      @render_threads=value
      true
    end
    def parallel_renderer_set_parallel_stretch(value)
      return false if @render_options_accepted == false
      @parallel_stretch=value
      true
    end
    def parallel_renderer_set_direct_output(value)
      return false if @render_options_accepted == false
      @direct_output=value
      true
    end
    def set_display_scaling_filter(value)
      return false if @filter_accepted == false
      @filter_mode=value
      true
    end
    def config_get(key); nil; end
    def fast_render_enabled; @snapshot_ready == false; end
    def parallel_renderer_health; 0; end
    def parallel_renderer_current_mode; @snapshot_mode || 0; end
    def parallel_renderer_last_error; @snapshot_error || ''; end
    def parallel_renderer_frame_status; '{"mode":'+(@snapshot_mode || 0).to_s+',"error":"'+(@snapshot_error || '')+'"}'; end
    def parallel_renderer_frame_mode(mode)
      (@snapshot_calls ||= []) << [:mode,mode]
      @snapshot_mode=mode
      true
    end
    def parallel_renderer_optimization(mode)
      (@snapshot_calls ||= []) << [:cache,mode]
      @cache_accepted != false
    end
    def parallel_renderer_memory_limit_mib; @snapshot_limit || 256; end
    def parallel_renderer_set_memory_limit_mib(value)
      return false unless (32..512).include?(value) && @snapshot_limit_accepted != false
      @snapshot_limit=value
      true
    end
    def configure_display(*args)
      (@display_calls ||= []) << args
      @display_accepted != false
    end
    def hrfix_enabled; @hrfix_on != false; end
    def hrfix_settings(pending)
      (pending ? (@render_pending ||= [1500, 840, false]) : (@render_active ||= [1500, 840, false])).dup
    end
    def save_hrfix_settings(*args)
      return false if @render_accepted == false
      @render_pending = args
      true
    end
  end
end
load File.expand_path('../mod_loader/framework/core/optimizations.rb', __dir__)
load File.expand_path('../mod_loader/framework/renderer/settings.rb', __dir__)
load File.expand_path('../mod_loader/framework/display/settings.rb', __dir__)

class ModLoaderDisplayTest < Minitest::Test
  def test_overlay_preferences_apply_restore_and_reject_invalid_values
    display = ModLoader::Display
    accepted = true
    active = 0
    ModLoader.define_singleton_method(:steam_overlay_optimizations) { active }
    ModLoader.define_singleton_method(:steam_overlay_set_optimizations) do |value|
      active = value if accepted
      accepted
    end
    assert display.send(:overlay_mode=, 4)
    assert_equal 4, display.settings[:overlay_mode]
    active = 0
    display.restore_overlay
    assert_equal 4, active
    accepted = false
    refute display.send(:overlay_mode=, 2)
    assert_equal 4, display.settings[:overlay_mode]
    refute display.send(:overlay_mode=, 5)
    display.settings[:overlay_mode] = 'bad'
    display.restore_overlay
    assert_equal 4, active
  ensure
    display.settings.delete(:overlay_mode)
    ModLoader.singleton_class.send(:remove_method, :steam_overlay_optimizations)
    ModLoader.singleton_class.send(:remove_method, :steam_overlay_set_optimizations)
  end

  def setup
    ModLoader.display_calls = []
    ModLoader.filter_mode=0; ModLoader.filter_accepted=true
    ModLoader::Display.settings.delete(:scaling_filter)
    ModLoader.display_accepted = ModLoader.render_accepted = ModLoader.hrfix_on = true
    ModLoader.render_active = [1500, 840, false]
    ModLoader.render_pending = [1500, 840, false]
    ModLoader::Display.settings[:mode] = :windowed
    ModLoader::Display.settings[:scaling] = :aspect
    ModLoader::Display.settings.delete(:wait_for_frame)
    ModLoader::Display.settings.delete(:parallel_rendering)
    ModLoader::Display.settings.delete(:memory_limit_mib)
    ModLoader::Display.settings.delete(:pixel_limit_mib)
    [:render_threads,:parallel_stretch,:direct_output].each {|key| ModLoader::Display.settings.delete(key)}
    ModLoader.render_threads=1;ModLoader.parallel_stretch=ModLoader.direct_output=false
    ModLoader.render_options_accepted=true
    ModLoader.snapshot_ready=ModLoader.cache_accepted=true
    ModLoader.snapshot_mode=0; ModLoader.snapshot_calls=[]
    ModLoader.snapshot_error=nil
    ModLoader.snapshot_limit=256
    ModLoader.snapshot_limit_accepted=true
    ModLoader::Display.renderer_notices=false
  end

  def item(label)
    entries = ModLoader::ModMenu.items_for('Display')
    advanced = entries.find { |entry| entry.label == 'Advanced' }
    (entries + advanced.definition.items).find { |entry| entry.label == label }
  end

  def test_optimizations_are_in_advanced_instead_of_a_separate_tab
    refute_includes ModLoader::ModMenu.categories, 'Optimizations'
    assert item('Optimizations')
    assert item('Glyph cache')
    assert item('Music replay')
  end

  def test_renderer_description_reads_structured_error_including_quotes_and_escapes
    ModLoader.snapshot_error = "failure: \"quoted\" path C:\\renderer\nnext line"
    assert_includes item('Parallel rendering').description_text, ModLoader.snapshot_error
  end

  def test_renderer_preferences_work_without_display_ui
    display = ModLoader::Display
    ModLoader.send(:remove_const, :Display)
    begin
      assert ModLoader::RendererSettings.send(:parallel_rendering=, true)
      assert_equal 3, ModLoader.snapshot_mode
      assert ModLoader::RendererSettings.save_memory_limit(192)
      assert_equal 192, ModLoader::RendererSettings.settings[:memory_limit_mib]
    ensure
      ModLoader.const_set(:Display, display)
    end
  end

  def test_render_options_save_and_restore_with_mode_after_restart
    refute item('Parallel viewport scaling').selectable?
    refute item('Direct frame output').selectable?
    item('Parallel rendering').value=true
    item('Render threads').value=3
    assert item('Parallel viewport scaling').selectable?
    item('Parallel viewport scaling').value=true
    item('Direct frame output').value=true
    assert_equal 3,ModLoader::Display.settings[:render_threads]
    assert_equal true,ModLoader::Display.settings[:parallel_stretch]
    assert_equal true,ModLoader::Display.settings[:direct_output]
    ModLoader.render_threads=1;ModLoader.parallel_stretch=ModLoader.direct_output=false;ModLoader.snapshot_mode=0
    assert ModLoader::Display.restore_renderer
    assert_equal [3,true,true,3],[ModLoader.render_threads,ModLoader.parallel_stretch,ModLoader.direct_output,ModLoader.snapshot_mode]
    item('Render threads').value=1
    refute item('Parallel viewport scaling').selectable?
    assert item('Parallel viewport scaling').value
  end

  def test_render_option_restore_applies_even_when_mode_is_already_active
    ModLoader::Display.settings[:render_threads]=2
    ModLoader::Display.settings[:parallel_stretch]=true
    ModLoader::Display.settings[:direct_output]=false
    ModLoader::Display.settings[:parallel_rendering]=true
    ModLoader.snapshot_mode=3;ModLoader.direct_output=true
    assert ModLoader::Display.restore_renderer
    assert_equal [2,true,false,3],[ModLoader.render_threads,ModLoader.parallel_stretch,ModLoader.direct_output,ModLoader.snapshot_mode]
  end

  def test_failed_or_invalid_render_options_do_not_change_saved_preferences
    settings=ModLoader::RendererSettings
    assert settings.send(:render_threads=,2)
    refute settings.send(:render_threads=,4)
    refute settings.send(:render_threads=,'3')
    refute settings.send(:parallel_stretch=,'true')
    ModLoader.render_options_accepted=false
    refute settings.send(:render_threads=,3)
    refute settings.send(:direct_output=,true)
    assert_equal 2,settings.settings[:render_threads]
    refute settings.settings.key?(:direct_output)
  end

  def test_corrupt_render_options_are_ignored_and_older_dll_restores_mode
    settings=ModLoader::RendererSettings
    settings.settings[:render_threads]=99
    settings.settings[:parallel_stretch]='true'
    settings.settings[:direct_output]=:enabled
    settings.settings[:parallel_rendering]=true
    assert settings.restore_renderer
    assert_equal [1,false,false,3],[ModLoader.render_threads,ModLoader.parallel_stretch,ModLoader.direct_output,ModLoader.snapshot_mode]
    singleton=class << ModLoader; self; end
    singleton.send(:alias_method,:saved_threads_setter,:parallel_renderer_set_workers)
    singleton.send(:remove_method,:parallel_renderer_set_workers)
    begin
      settings.settings[:render_threads]=3
      ModLoader.snapshot_mode=0
      refute item('Render threads').selectable?
      assert settings.restore_renderer
      assert_equal 3,ModLoader.snapshot_mode
      assert_equal 1,ModLoader.render_threads
    ensure
      singleton.send(:alias_method,:parallel_renderer_set_workers,:saved_threads_setter)
      singleton.send(:remove_method,:saved_threads_setter)
    end
  end

  def test_parallel_toggle_defaults_to_nonblocking_and_drains_before_cache_change
    item('Parallel rendering').value=true
    assert_equal true,ModLoader::Display.settings[:parallel_rendering]
    assert_equal [[:mode,0],[:cache,2],[:mode,3]], ModLoader.snapshot_calls
    assert item('Parallel rendering').value
    refute item('Wait for new frame').value
    assert item('Wait for new frame').selectable?
    item('Wait for new frame').value=true
    assert_equal 2, ModLoader.snapshot_mode
    item('Parallel rendering').value=false
    assert_equal false,ModLoader::Display.settings[:parallel_rendering]
    assert_equal 0, ModLoader.snapshot_mode
    refute item('Wait for new frame').selectable?
    item('Parallel rendering').value=true
    assert_equal 2, ModLoader.snapshot_mode
  end

  def test_saved_parallel_mode_resumes_after_native_reset
    item('Parallel rendering').value=true
    item('Wait for new frame').value=true
    assert_equal 2,ModLoader.snapshot_mode
    ModLoader.snapshot_mode=0
    assert ModLoader::Display.restore_renderer
    assert_equal 2,ModLoader.snapshot_mode
    item('Parallel rendering').value=false
    ModLoader.snapshot_mode=0
    assert ModLoader::Display.restore_renderer
    assert_equal 0,ModLoader.snapshot_mode
  end

  def test_snapshot_limit_slider_saves_value_and_restores_it_on_next_start
    limit=item('Renderer memory limit')
    assert limit.selectable?
    assert_equal 256,limit.value
    limit.value=192
    assert_equal 192,ModLoader.snapshot_limit
    assert_equal 192,limit.value
    assert_equal 192,ModLoader::Display.settings[:memory_limit_mib]
    ModLoader.snapshot_limit=256
    assert ModLoader::Display.restore_memory_limit
    assert_equal 192,ModLoader.snapshot_limit
    ModLoader.snapshot_ready=false
    refute limit.selectable?
  end

  def test_failed_limit_change_keeps_saved_value
    ModLoader.snapshot_limit_accepted=false
    refute ModLoader::Display.save_memory_limit(192)
    refute ModLoader::Display.settings.key?(:memory_limit_mib)
    assert_equal 256,ModLoader.snapshot_limit
  end

  def test_scaling_filter_changes_now_and_restores_without_changing_resolution
    filter=item('Scaling filter')
    assert filter.selectable?
    assert_equal :pixelated,filter.value
    filter.value=:smooth
    assert_equal 1,ModLoader.filter_mode
    assert_equal :smooth,ModLoader::Display.settings[:scaling_filter]
    assert_equal [1500,840,false],ModLoader.render_active
    assert_empty ModLoader.display_calls
    ModLoader.filter_mode=0
    ModLoader::Display.instance_variable_set(:@settings,nil)
    assert ModLoader::Display.restore_scaling_filter
    assert_equal 1,ModLoader.filter_mode
  end

  def test_invalid_failed_and_legacy_filter_settings
    ModLoader::Display.settings[:scaling_filter]=:obsolete
    assert ModLoader::Display.restore_scaling_filter
    assert_equal 0,ModLoader.filter_mode
    refute ModLoader::Display.send(:scaling_filter=,:unknown)
    ModLoader.filter_accepted=false
    refute ModLoader::Display.send(:scaling_filter=,:smooth)
    assert_equal :obsolete,ModLoader::Display.settings[:scaling_filter]
    singleton=class << ModLoader;self;end
    singleton.send(:alias_method,:saved_filter_setter,:set_display_scaling_filter)
    singleton.send(:remove_method,:set_display_scaling_filter)
    begin
      refute item('Scaling filter').selectable?
      assert ModLoader::Display.restore_scaling_filter
    ensure
      singleton.send(:alias_method,:set_display_scaling_filter,:saved_filter_setter)
      singleton.send(:remove_method,:saved_filter_setter)
    end
  end

  def test_renderer_warning_preference_and_memory_limit_bounds
    notice=item('Renderer warnings')
    refute notice.value
    notice.value=true
    assert notice.value
    assert_equal true,ModLoader::Display.settings[:renderer_notices]
    assert ModLoader::Display.save_memory_limit(32)
    assert ModLoader::Display.save_memory_limit(512)
    refute ModLoader::Display.save_memory_limit(31)
    refute ModLoader::Display.save_memory_limit(513)
    assert_equal 512,ModLoader.snapshot_limit
  end

  def test_menu_reads_actual_mode_after_native_error_or_reset
    item('Parallel rendering').value=true
    ModLoader.snapshot_mode=0
    refute item('Parallel rendering').value
    refute item('Wait for new frame').selectable?
    ModLoader.snapshot_ready=false
    refute item('Parallel rendering').selectable?
    refute ModLoader::Display.change_renderer(3)
  end

  def test_renderer_failure_reason_is_visible_without_console
    ModLoader.snapshot_error='Pipelined Screen pixels differ from captured reference'
    assert_includes item('Parallel rendering').description_text, 'Renderer stopped: '
    assert_includes item('Parallel rendering').description_text, ModLoader.snapshot_error
    ModLoader.snapshot_mode=3
    ModLoader.snapshot_error='Custom ViewportEffects require live rendering'
    assert_includes item('Parallel rendering').description_text, 'Original renderer temporarily active: '
    ModLoader.snapshot_error=nil
    refute_includes item('Parallel rendering').description_text, 'Renderer stopped: '
  end

  def test_render_menu_only_saves_for_restart_including_custom_startup_size
    assert_includes item('Render resolution').instance_variable_get(:@opts)[:values], '1500x840'
    item('Render resolution').value = '1920x1080'
    item('Map size').value = :original
    assert_equal [1920, 1080, true], ModLoader.render_pending
    assert_equal [1500, 840, false], ModLoader.render_active
    assert_empty ModLoader.display_calls
    assert ModLoader::Display.restart_required?
    ModLoader.render_active = ModLoader.render_pending.dup # next process start
    refute ModLoader::Display.restart_required?
  end

  def test_default_map_behavior_and_disabled_hrfix
    assert_equal :render, ModLoader::Display.map_size
    ModLoader.hrfix_on = false
    refute item('Render resolution').selectable?
    refute item('Map size').selectable?
    refute ModLoader::Display.save_render('800x600', :original)
    assert_equal [1500, 840, false], ModLoader.render_pending
  end

  def test_optional_ruby_toggle_and_scaling_do_not_change_render_preferences
    item('Scaling').value = :stretch
    item('Window mode').value = :borderless
    assert_equal [1, 0, 0, 1], ModLoader.display_calls.last
    assert_equal [1500, 840, false], ModLoader.render_pending
    refute ModLoader::Hotkeys.instance_variable_get(:@actions).key?(:display)
    ModLoader::Display.toggle
    assert_equal [0, 0, 0, 1], ModLoader.display_calls.last
  end

  def test_invalid_or_missing_presentation_settings_use_defaults
    ModLoader::Display.settings[:mode] = :obsolete
    ModLoader::Display.settings.delete(:scaling)
    # The old window-resolution preference must not overwrite HRFix's config.
    ModLoader::Display.settings[:resolution] = '800x600'
    assert ModLoader::Display.apply
    assert_equal [0, 0, 0, 0], ModLoader.display_calls.last
    assert_equal '1500x840', ModLoader::Display.resolution
  end

  def test_failed_saves_and_invalid_values_preserve_pending_configuration
    refute ModLoader::Display.save_render('99999x99999', :render)
    refute ModLoader::Display.save_render('800x600', :unknown)
    ModLoader.render_accepted = false
    refute ModLoader::Display.save_render('800x600', :original)
    assert_equal [1500, 840, false], ModLoader.render_pending
    refute ModLoader::Display.restart_required?
    refute ModLoader::Display.apply(:exclusive, :stretch)
    ModLoader.display_accepted = false
    refute ModLoader::Display.apply(:borderless, :stretch)
    assert_equal :windowed, ModLoader::Display.mode
  end

  def test_reload_keeps_pending_native_preferences_and_presentation
    ModLoader::Display.save_render('1024x768', :original)
    ModLoader::Display.apply(:borderless, :stretch)
    ModLoader::Display.instance_variable_set(:@settings, nil)
    ModLoader::Display.apply
    assert_equal [1, 0, 0, 1], ModLoader.display_calls.last
    assert_equal '1024x768', ModLoader::Display.resolution
    assert_equal :original, ModLoader::Display.map_size
    assert ModLoader::Display.restart_required?
  end
end
