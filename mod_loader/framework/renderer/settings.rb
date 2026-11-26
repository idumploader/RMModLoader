# Persistent renderer preferences are independent of the Display menu.
$imported ||= {}
unless $imported['IDL-RendererSettings']
  $imported['IDL-RendererSettings'] = '1.0'
  module ModLoader
    # Native control has no menu or NVRAM dependency.
    module RendererControl
      class << self
        def last_error
          ModLoader.respond_to?(:parallel_renderer_last_error) ? ModLoader.parallel_renderer_last_error : ''
        end

        def renderer_available?
          ModLoader.respond_to?(:parallel_renderer_frame_mode) &&
            ModLoader.respond_to?(:parallel_renderer_current_mode) &&
            ModLoader.respond_to?(:parallel_renderer_optimization) &&
            !ModLoader.fast_render_enabled
        rescue StandardError
          false
        end

        def renderer_mode
          return 0 unless renderer_available?
          ModLoader.parallel_renderer_current_mode
        end

        def change_renderer(mode)
          return false unless renderer_available?
          # Drain before changing cache policy or replacing an active queue.
          ok = ModLoader.parallel_renderer_frame_mode(0)
          ok &&= ModLoader.parallel_renderer_optimization(2) if mode != 0
          ok &&= ModLoader.parallel_renderer_frame_mode(mode) if mode != 0
          !!ok
        end

        def memory_limit_available?
          renderer_available? &&
            ModLoader.respond_to?(:parallel_renderer_memory_limit_mib) &&
            ModLoader.respond_to?(:parallel_renderer_set_memory_limit_mib)
        end

        def render_threads_available?
          renderer_available? && ModLoader.respond_to?(:parallel_renderer_workers) &&
            ModLoader.respond_to?(:parallel_renderer_set_workers)
        end
        def render_threads; render_threads_available? ? ModLoader.parallel_renderer_workers : 1; end
        def set_render_threads(value)
          return false unless render_threads_available? && value.is_a?(Integer) && (1..3).include?(value)
          !!ModLoader.parallel_renderer_set_workers(value)
        end
        def parallel_stretch_available?
          renderer_available? && ModLoader.respond_to?(:parallel_renderer_set_parallel_stretch) &&
            (ModLoader.respond_to?(:parallel_renderer_parallel_stretch) || ModLoader.respond_to?(:parallel_renderer_frame_status))
        end
        def parallel_stretch?
          return false unless parallel_stretch_available?
          return ModLoader.parallel_renderer_parallel_stretch if ModLoader.respond_to?(:parallel_renderer_parallel_stretch)
          # Compatibility with the measured preview DLL, before the integer/
          # boolean getter was added. This status poll only serves menu reads.
          ModLoader.parallel_renderer_frame_status.include?('"parallel_stretch":true')
        end
        def set_parallel_stretch(value)
          return false unless parallel_stretch_available? && [true,false].include?(value)
          !!ModLoader.parallel_renderer_set_parallel_stretch(value)
        end
        def direct_output_available?
          renderer_available? && ModLoader.respond_to?(:parallel_renderer_direct_output) &&
            ModLoader.respond_to?(:parallel_renderer_set_direct_output)
        end
        def direct_output?; direct_output_available? && ModLoader.parallel_renderer_direct_output; end
        def set_direct_output(value)
          return false unless direct_output_available? && [true,false].include?(value)
          !!ModLoader.parallel_renderer_set_direct_output(value)
        end

        def memory_limit_mib
          memory_limit_available? ? ModLoader.parallel_renderer_memory_limit_mib : 256
        end

        def set_memory_limit(value)
          return false unless memory_limit_available? && value.is_a?(Integer) &&
            value >= 32 && value <= 512
          !!ModLoader.parallel_renderer_set_memory_limit_mib(value)
        end
      end
    end

    module RendererSettings
      class << self
        def settings
          ModLoader.nvram.section(:display)
        end
        def last_error; RendererControl.last_error; end

        def renderer_available?; RendererControl.renderer_available?; end

        def renderer_mode; RendererControl.renderer_mode; end

        def parallel_rendering?; [2,3].include?(renderer_mode); end
        def wait_for_frame?; parallel_rendering? ? renderer_mode == 2 : settings[:wait_for_frame] == true; end

        def change_renderer(mode); RendererControl.change_renderer(mode); end

        def parallel_rendering=(enabled)
          ok=change_renderer(enabled ? (wait_for_frame? ? 2 : 3) : 0)
          if ok
            settings[:parallel_rendering]=!!enabled
            settings.commit
          end
          ok
        end

        def restore_renderer
          return false unless restore_render_options
          return true unless settings[:parallel_rendering] == true
          target=settings[:wait_for_frame] == true ? 2 : 3
          return true if renderer_mode == target
          change_renderer(target)
        end

        def render_threads_available?; RendererControl.render_threads_available?; end
        def render_threads; RendererControl.render_threads; end
        def parallel_stretch_available?; RendererControl.parallel_stretch_available?; end
        def parallel_stretch?; RendererControl.parallel_stretch?; end
        def direct_output_available?; RendererControl.direct_output_available?; end
        def direct_output?; RendererControl.direct_output?; end

        def save_render_option(key,value)
          return false unless RendererControl.send("set_#{key}",value)
          settings[key]=value
          settings.commit
          true
        end
        def render_threads=(value); save_render_option(:render_threads,value); end
        def parallel_stretch=(value); save_render_option(:parallel_stretch,value); end
        def direct_output=(value); save_render_option(:direct_output,value); end

        def restore_render_options
          # Optional new APIs must not prevent older DLLs from restoring mode.
          ok=true
          threads=settings[:render_threads]
          if render_threads_available? && threads.is_a?(Integer) && (1..3).include?(threads) && render_threads!=threads
            ok=RendererControl.set_render_threads(threads) && ok
          end
          [:parallel_stretch,:direct_output].each do |key|
            value=settings[key]
            next unless RendererControl.send("#{key}_available?") && [true,false].include?(value)
            next if RendererControl.send("#{key}?")==value
            ok=RendererControl.send("set_#{key}",value) && ok
          end
          ok
        end

        def wait_for_frame=(enabled)
          return false if parallel_rendering? && !change_renderer(enabled ? 2 : 3)
          settings[:wait_for_frame] = !!enabled
          settings.commit
          true
        end

        def renderer_notices?; @renderer_notices == true; end
        def renderer_notices=(enabled)
          @renderer_notices = !!enabled
          settings[:renderer_notices] = @renderer_notices
          settings.commit
          RendererNotice.clear if !@renderer_notices && defined?(RendererNotice)
        end

        def memory_limit_available?; RendererControl.memory_limit_available?; end

        def memory_limit_mib; RendererControl.memory_limit_mib; end

        def save_memory_limit(value)
          ok = RendererControl.set_memory_limit(value)
          if ok
            settings[:memory_limit_mib]=value
            settings.commit
          end
          !!ok
        end

        def memory_limit_mib=(value); save_memory_limit(value); end

        def restore_memory_limit
          value=settings[:memory_limit_mib]
          return true if value.nil?
          RendererControl.set_memory_limit(value)
        end
        alias pixel_limit_mib memory_limit_mib
        alias pixel_limit_mib= memory_limit_mib=
        alias save_pixel_limit save_memory_limit
        alias restore_pixel_limit restore_memory_limit
      end
    end
    if defined?(Lifecycle)
      Lifecycle.register(:before_run, :renderer_settings, 20) do
        RendererSettings.restore_memory_limit
        RendererSettings.restore_renderer
      end
    end
  end
end
