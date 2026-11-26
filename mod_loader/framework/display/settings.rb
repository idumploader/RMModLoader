# Presentation applies immediately. Live HRFix resizing is deferred until the
# menu closes; older DLLs require a restart.
$imported ||= {}
unless $imported["IDL-ModLoaderDisplay"]
$imported["IDL-ModLoaderDisplay"] = "1.0"

# Older loader DLLs do not export the display API.
if ModLoader.respond_to?(:configure_display) && ModLoader.respond_to?(:hrfix_settings)
module ModLoader
  module Display
    RESOLUTIONS = ["640x480", "800x600", "960x720", "1024x768", "1280x720",
                   "1280x960", "1600x900", "1920x1080", "1920x1440", "2560x1440"]
    MODES = [:windowed, :borderless]
    SCALING = [:aspect, :stretch]
    FILTERS = [:pixelated, :smooth]
    MAP_SIZES = [:render, :original]

    class << self
      def settings
        @settings ||= ModLoader.nvram.section(:display,
          :mode => :windowed, :scaling => :aspect)
      end

      def mode
        MODES.include?(settings[:mode]) ? settings[:mode] : :windowed
      end

      def scaling
        SCALING.include?(settings[:scaling]) ? settings[:scaling] : :aspect
      end

      def apply(mode_value = mode, scaling_value = scaling)
        return false unless MODES.include?(mode_value) && SCALING.include?(scaling_value)
        return false unless ModLoader.configure_display(MODES.index(mode_value), 0, 0, SCALING.index(scaling_value))
        settings[:mode] = mode_value
        settings[:scaling] = scaling_value
        settings.commit
        true
      end

      def mode=(value); apply(value, scaling); end
      def scaling=(value); apply(mode, value); end
      def toggle; self.mode = mode == :windowed ? :borderless : :windowed; end

      def filter_available?; ModLoader.respond_to?(:set_display_scaling_filter); end
      def scaling_filter
        FILTERS.include?(settings[:scaling_filter]) ? settings[:scaling_filter] : :pixelated
      end
      def scaling_filter=(value)
        return false unless filter_available? && FILTERS.include?(value)
        return false unless ModLoader.set_display_scaling_filter(FILTERS.index(value))
        settings[:scaling_filter] = value
        settings.commit
        true
      end
      def restore_scaling_filter
        return true unless filter_available?
        !!ModLoader.set_display_scaling_filter(FILTERS.index(scaling_filter))
      end

      def resolution; @live_resolution || ModLoader.hrfix_settings(true)[0, 2].join("x"); end
      def resolutions; (RESOLUTIONS + [resolution]).uniq; end
      def map_size; @live_map_size || (ModLoader.hrfix_settings(true)[2] ? :original : :render); end
      def restart_required?; ModLoader.hrfix_settings(true) != ModLoader.hrfix_settings(false); end

      def save_render(resolution_value = resolution, map_value = map_size)
        return false unless ModLoader.hrfix_enabled && resolutions.include?(resolution_value) && MAP_SIZES.include?(map_value)
        size = resolution_value.split("x").map { |v| v.to_i }
        ModLoader.save_hrfix_settings(size[0], size[1], map_value == :original)
      end

      def live_resize_available?; ModLoader.respond_to?(:apply_hrfix_resolution); end
      def live_resize_scene?
        defined?(SceneManager) && defined?(Scene_Map) && defined?(Scene_Title) && SceneManager.scene &&
          [Scene_Map, Scene_Title].include?(SceneManager.scene.class)
      end
      def resolution=(value)
        return save_render(value, map_size) unless live_resize_available?
        return false unless ModLoader.hrfix_enabled && resolutions.include?(value) && live_resize_scene?
        @live_resolution = value
        true
      end
      def overlay_available?; ModLoader.respond_to?(:steam_overlay_optimizations); end
      def overlay_mode; overlay_available? ? ModLoader.steam_overlay_optimizations : 0; end
      def overlay_mode=(value)
        return false unless overlay_available? && (0..4).include?(value)
        return false unless ModLoader.steam_overlay_set_optimizations(value)
        settings[:overlay_mode] = value
        settings.commit
        true
      end
      def restore_overlay
        value = settings[:overlay_mode]
        ModLoader.steam_overlay_set_optimizations(value) if overlay_available? && value.is_a?(Integer) && (0..4).include?(value)
      end
      def live_map_size_available?
        live_resize_available? && ModLoader.respond_to?(:apply_hrfix_map_size) && defined?(HRFix::MapSize)
      end
      def map_size=(value)
        return save_render(resolution, value) unless live_map_size_available?
        return false unless ModLoader.hrfix_enabled && MAP_SIZES.include?(value) && live_resize_scene?
        @live_map_size = value
        true
      end
      def report_save(result)
        msgbox(ModMenu.tr("Could not save display settings. Check the ModLoader log.")) unless result
      end

      def renderer_available?; RendererSettings.renderer_available?; end
      def renderer_mode; RendererSettings.renderer_mode; end
      def parallel_rendering?; RendererSettings.parallel_rendering?; end
      def wait_for_frame?; RendererSettings.wait_for_frame?; end
      def render_threads_available?; RendererSettings.render_threads_available?; end
      def render_threads; RendererSettings.render_threads; end
      def parallel_stretch_available?; RendererSettings.parallel_stretch_available?; end
      def parallel_stretch?; RendererSettings.parallel_stretch?; end
      def direct_output_available?; RendererSettings.direct_output_available?; end
      def direct_output?; RendererSettings.direct_output?; end
      def render_threads=(value)
        ok=RendererSettings.send(:render_threads=,value)
        report_renderer_change(ok)
        ok
      end
      def parallel_stretch=(value)
        ok=RendererSettings.send(:parallel_stretch=,value)
        report_renderer_change(ok)
        ok
      end
      def direct_output=(value)
        ok=RendererSettings.send(:direct_output=,value)
        report_renderer_change(ok)
        ok
      end
      def restore_renderer; RendererSettings.restore_renderer; end
      def renderer_notices?; RendererSettings.renderer_notices?; end
      def memory_limit_available?; RendererSettings.memory_limit_available?; end
      def memory_limit_mib; RendererSettings.memory_limit_mib; end
      def restore_memory_limit; RendererSettings.restore_memory_limit; end
      def parallel_rendering=(value)
        ok = RendererSettings.send(:parallel_rendering=, value)
        report_renderer_change(ok)
        ok
      end
      def wait_for_frame=(value)
        ok = RendererSettings.send(:wait_for_frame=, value)
        report_renderer_change(ok)
        ok
      end
      def renderer_notices=(value); RendererSettings.renderer_notices = value; end
      def change_renderer(mode, notify = true)
        return false unless renderer_available?
        ok = RendererSettings.change_renderer(mode)
        report_renderer_change(ok) if notify
        ok
      end
      def report_renderer_change(ok)
        msgbox(ModMenu.tr("Could not change the renderer. Check the ModLoader log.")) unless ok
      end
      def save_memory_limit(value, notify = false)
        ok = RendererSettings.save_memory_limit(value)
        msgbox(ModMenu.tr("Could not change the renderer memory limit. Check the ModLoader log.")) if !ok && notify
        ok
      end
      def memory_limit_mib=(value); save_memory_limit(value, true); end
      alias pixel_limit_mib memory_limit_mib
      alias pixel_limit_mib= memory_limit_mib=
      alias save_pixel_limit save_memory_limit
      alias restore_pixel_limit restore_memory_limit
      def renderer_description
        error = RendererSettings.last_error if renderer_available?
        if error && !error.empty?
          label = renderer_mode == 0 ? "Renderer stopped: " : "Original renderer temporarily active: "
          return ModMenu.tr(label) + error
        end
        ModMenu.tr("May improve performance, but the picture can lag behind your input. Off uses the original renderer. Applies immediately and is saved.")
      end
    end
  end

  ModMenu.category("Display", :id => :modloader_display) do |menu|
    menu.choice("Window mode",
      :description => "Borderless fills the monitor without changing its resolution. Scaling controls how the image fills the window.",
      :values => Display::MODES, :labels => ["Windowed", "Borderless fullscreen"],
      :get => proc { Display.mode }, :set => proc { |v| Display.mode = v })
    menu.choice("Scaling",
      :description => "Keep aspect ratio adds black bars where needed. Stretch fills the whole window but may distort the image. Applies to both window modes.",
      :values => Display::SCALING, :labels => ["Keep aspect ratio", "Stretch"],
      :get => proc { Display.scaling }, :set => proc { |v| Display.scaling = v })
    menu.choice("Scaling filter",
      :description => "Pixelated keeps sharp pixels. Smooth may blur text and cost performance. Changes window scaling only; applies immediately and is saved.",
      :enabled => proc { Display.filter_available? },
      :values => Display::FILTERS, :labels => ["Pixelated", "Smooth"],
      :get => proc { Display.scaling_filter }, :set => proc { |v| Display.scaling_filter = v })
    menu.choice("Render resolution",
      :description => proc { Display.live_resize_available? ? "Higher resolutions make text and detailed images clearer, but can slow the game. Applies after closing this menu on the map or title screen. Your choice is saved." : "Higher resolutions make text and detailed images clearer, but can slow the game. Requires HRFix and a full game restart; F12 is not enough." },
      :enabled => proc { ModLoader.hrfix_enabled && (!Display.live_resize_available? || Display.live_resize_scene?) }, :values => Display.resolutions,
      :get => proc { Display.resolution },
      :set => proc { |v| Display.report_save(Display.send(:resolution=, v)) })
    menu.choice("Map size",
      :description => proc { Display.live_map_size_available? ? "Original 640x480 keeps the original map view and enlarges it to fill the screen. Match render resolution shows more of the map. Text stays sharp. Applies after closing this menu and is saved." : "Original 640x480 keeps the original map view and enlarges it to fill the screen. Match render resolution shows more of the map. Text stays sharp. Requires a full game restart." },
      :enabled => proc { ModLoader.hrfix_enabled && (!Display.live_map_size_available? || Display.live_resize_scene?) },
      :values => Display::MAP_SIZES, :labels => ["Match render resolution", "Original 640x480"],
      :get => proc { Display.map_size },
      :set => proc { |v| Display.report_save(Display.send(:map_size=, v)) })
    menu.submenu("Advanced") do |menu|
      Optimizations.register_menu(menu) if defined?(Optimizations)
      menu.header("Rendering")
      menu.toggle("Parallel rendering",
        :description => proc { Display.renderer_description },
        :enabled => proc { Display.renderer_available? },
        :get => proc { Display.parallel_rendering? }, :set => proc { |v| Display.parallel_rendering = v })
      menu.toggle("Wait for new frame",
        :description => "On waits for a newly drawn frame before continuing the game. Off keeps the game running when drawing is slow, but may repeat the last frame. Applies immediately and is saved.",
        :enabled => proc { Display.renderer_available? && Display.parallel_rendering? },
        :get => proc { Display.wait_for_frame? }, :set => proc { |v| Display.wait_for_frame = v })
      menu.slider("Renderer memory limit",
        :description => "How much memory parallel rendering may use. A higher limit can prevent temporary switches to the original renderer in complex scenes. The game also needs memory of its own. Your choice is saved.",
        :enabled => proc { Display.memory_limit_available? },
        :min => 32, :max => 512, :step => 16,
        :format => proc { |v| "#{v} MiB" },
        :get => proc { Display.memory_limit_mib }, :set => proc { |v| Display.memory_limit_mib = v })
      menu.choice("Render threads",
        :description => "More threads may improve performance at high resolutions. If the game runs worse, try a lower value. Applies immediately and is saved.",
        :enabled => proc { Display.render_threads_available? },
        :values => [1,2,3], :labels => ["1","2","3"],
        :get => proc { Display.render_threads }, :set => proc { |v| Display.render_threads = v })
      menu.toggle("Parallel viewport scaling",
        :description => "May improve performance when Map size is Original 640x480. Requires parallel rendering and at least two render threads. Applies immediately and is saved.",
        :enabled => proc { Display.parallel_stretch_available? && Display.parallel_rendering? && Display.render_threads > 1 },
        :get => proc { Display.parallel_stretch? }, :set => proc { |v| Display.parallel_stretch = v })
      menu.toggle("Direct frame output",
        :description => "May improve performance with parallel rendering. The benefit depends on your computer; compare both settings. Applies immediately and is saved.",
        :enabled => proc { Display.direct_output_available? && Display.parallel_rendering? },
        :get => proc { Display.direct_output? }, :set => proc { |v| Display.direct_output = v })
      menu.toggle("Last frame menu background",
        :description => "May reduce the pause when opening a menu by using the last displayed frame as its background. Off takes a new picture. Applies immediately and is saved.",
        :enabled => proc { defined?(LastFrameSnapshot) && LastFrameSnapshot.available? },
        :get => proc { defined?(LastFrameSnapshot) && LastFrameSnapshot.enabled? },
        :set => proc { |v| LastFrameSnapshot.enabled = v if defined?(LastFrameSnapshot) })
      menu.toggle("Fast menu blur",
        :description => "Speeds up menu background blur without changing its appearance. Applies immediately and is saved.",
        :enabled => proc { defined?(MenuRendering) && MenuRendering.blur_available? },
        :get => proc { defined?(MenuRendering) && MenuRendering.fast_blur? },
        :set => proc { |v| MenuRendering.fast_blur = v if defined?(MenuRendering) })
      menu.choice("Menu transitions",
        :description => "Normal keeps the usual menu animation. Fast makes it twice as short. Off removes the animation, but still waits for the menu to load. Your choice is saved.",
        :enabled => proc { defined?(MenuRendering) },
        :values => [:normal, :fast, :off], :labels => ["Normal", "Fast", "Off"],
        :get => proc { defined?(MenuRendering) ? MenuRendering.transition_mode : :normal },
        :set => proc { |v| MenuRendering.transition_mode = v if defined?(MenuRendering) })
      menu.toggle("Renderer warnings",
        :description => "Show a message if parallel rendering stops or temporarily switches to the original renderer. Applies immediately and is saved.",
        :enabled => proc { ModLoader.respond_to?(:parallel_renderer_health) },
        :get => proc { Display.renderer_notices? }, :set => proc { |v| Display.renderer_notices = v })
      menu.choice("Steam Overlay rendering",
        :description => "May reduce slowdown while the Steam overlay is open. The best mode depends on your computer. Choose Original if another mode causes problems. Applies immediately and is saved.",
        :enabled => proc { Display.overlay_available? }, :values => [0,1,2,3,4],
        :labels => ["Original", "Shared workers", "Separate workers", "Shared workers + copy on write", "Separate workers + copy on write"],
        :get => proc { Display.overlay_mode }, :set => proc { |v| Display.report_renderer_change(Display.send(:overlay_mode=, v)) })
    end
  end

  if defined?(Lifecycle)
    Lifecycle.register(:before_run, :display_filter, 10) { Display.restore_scaling_filter }
    Lifecycle.register(:before_run, :display_overlay, 10) { Display.restore_overlay }
    Lifecycle.register(:cleanup, :display_resize, 10) { Display.cancel_live_resize }
  end
  Display.apply
  Display.restore_scaling_filter
  Display.renderer_notices = Display.settings[:renderer_notices] == true
  Display.restore_memory_limit
  Display.restore_renderer
  Display.restore_overlay
end
end
end
