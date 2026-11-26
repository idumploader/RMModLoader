# Snapshot diagnostics for the parallel renderer; fast_render must be off.
# Captures a viewport or the Screen; explicit APIs can also run the worker.
# Call after Graphics.update has prepared native sprite geometry.
#
#   probe = ModLoader::ParallelRenderer
#   probe.capture(viewport)
#   probe.draw(destination_bitmap) # can run after originals have been disposed
#   puts probe.status             # JSON: sizes, timings, last native error
#   probe.clear

$imported ||= {}
unless $imported["IDL-ParallelRenderer"]
$imported["IDL-ParallelRenderer"] = "1.0"
$imported["IDL-RenderSnapshotProbe"] = "1.0"

module ModLoader
  module ParallelRenderer
    class << self
      def available?
        ModLoader.respond_to?(:parallel_renderer_capture)
      end

      def capture(viewport)
        require_available
        # Discard first: validation failure must not leave an older snapshot
        # available under the mistaken assumption that this capture succeeded.
        clear
        validate(viewport, ::Viewport)
        check(ModLoader.parallel_renderer_capture(viewport))
      end

      # Capture the complete native Screen tree in its existing draw order.
      def capture_frame
        require_available
        clear
        check(ModLoader.parallel_renderer_capture(nil))
      end

      def submit_frame(template, repeats = 1)
        require_available
        validate(template, ::Bitmap)
        validate_repeats(repeats)
        check(ModLoader.parallel_renderer_submit(nil, template, repeats))
      end

      def reference_frame(bitmap)
        require_available
        validate(bitmap, ::Bitmap)
        check(ModLoader.parallel_renderer_reference(nil, bitmap))
      end

      def draw(bitmap)
        require_available
        validate(bitmap, ::Bitmap)
        check(ModLoader.parallel_renderer_draw(bitmap))
      end

      # Copies the template pixels; no Ruby object is retained by the worker.
      # Repeats are for stress testing, with the template restored each time.
      def start(template, repeats = 1)
        require_available
        validate(template, ::Bitmap)
        validate_repeats(repeats)
        check(ModLoader.parallel_renderer_start(template, repeats))
      end

      # Wait, then copy the finished pixels into an equally sized Bitmap.
      def collect(bitmap)
        require_available
        validate(bitmap, ::Bitmap)
        check(ModLoader.parallel_renderer_collect(bitmap))
      end

      # Capture and enqueue without clearing earlier frames. At most two results
      # can be outstanding; collect returns them in submission order.
      def submit(viewport, template, repeats = 1)
        require_available
        validate(viewport, ::Viewport)
        validate(template, ::Bitmap)
        validate_repeats(repeats)
        check(ModLoader.parallel_renderer_submit(viewport, template, repeats))
      end

      # Reference uses the same native walker on the live subtree, for pixel
      # comparison. Neither operation clears the destination: supply a fresh or
      # cleared Bitmap when comparing transparent sprites.
      def reference(viewport, bitmap)
        require_available
        validate(viewport, ::Viewport)
        validate(bitmap, ::Bitmap)
        check(ModLoader.parallel_renderer_reference(viewport, bitmap))
      end

      def clear
        require_available
        check(ModLoader.parallel_renderer_clear)
      end

      def status
        require_available
        ModLoader.parallel_renderer_status
      end

      # Renderer buffer budget. The old pixel_limit name remains an alias.
      def memory_limit_mib
        require_available
        ModLoader.parallel_renderer_memory_limit_mib
      end

      def memory_limit_mib=(value)
        require_available
        raise ArgumentError, "Expected Integer limit in 32..512 MiB" unless
          value.is_a?(Integer) && value >= 32 && value <= 512
        if defined?(ModLoader::RendererSettings)
          check(ModLoader::RendererSettings.save_memory_limit(value))
        else
          check(ModLoader.parallel_renderer_set_memory_limit_mib(value))
        end
      end

      alias pixel_limit_mib memory_limit_mib
      alias pixel_limit_mib= memory_limit_mib=

      def workers
        require_available
        ModLoader.parallel_renderer_workers
      end
      def workers=(value)
        require_available
        raise ArgumentError, "Expected Integer threads in 1..3" unless value.is_a?(Integer) && (1..3).include?(value)
        check(defined?(ModLoader::RendererSettings) ?
          ModLoader::RendererSettings.send(:render_threads=,value) : ModLoader.parallel_renderer_set_workers(value))
      end
      def parallel_stretch?
        defined?(ModLoader::RendererSettings) ? ModLoader::RendererSettings.parallel_stretch? : ModLoader.parallel_renderer_parallel_stretch
      end
      def parallel_stretch=(value)
        require_available
        check(defined?(ModLoader::RendererSettings) ?
          ModLoader::RendererSettings.send(:parallel_stretch=,!!value) : ModLoader.parallel_renderer_set_parallel_stretch(!!value))
      end
      def direct_output?
        defined?(ModLoader::RendererSettings) ? ModLoader::RendererSettings.direct_output? : ModLoader.parallel_renderer_direct_output
      end
      def direct_output=(value)
        require_available
        check(defined?(ModLoader::RendererSettings) ?
          ModLoader::RendererSettings.send(:direct_output=,!!value) : ModLoader.parallel_renderer_set_direct_output(!!value))
      end

      def validation=(enabled)
        check(ModLoader.parallel_renderer_validation(!!enabled))
      end

      # Cache modes: baseline, cached sources, cached + pooled targets.
      # Switching requires an empty queue and resets the cache/counters.
      def optimization(mode)
        require_available
        raise ArgumentError, "Expected Integer mode in 0..2" unless mode.is_a?(Integer) && mode >= 0 && mode <= 2
        check(ModLoader.parallel_renderer_optimization(mode))
      end

      # Call after extensions that write pixel memory outside standard Bitmap APIs.
      def invalidate(bitmap)
        require_available
        validate(bitmap, ::Bitmap)
        check(ModLoader.parallel_renderer_invalidate(bitmap))
      end

      private

      def require_available
        raise "Parallel rendering is unavailable; check fast_render and the x86 DLL" unless available?
      end

      def validate_repeats(repeats)
        raise ArgumentError, "Expected Integer repeats in 1..10000" unless
          repeats.is_a?(Integer) && repeats >= 1 && repeats <= 10000
      end

      def validate(object, klass)
        raise ArgumentError, "Expected an exact #{klass} instance" unless object.instance_of?(klass)
        raise ArgumentError, "#{klass} is disposed" if object.disposed?
      end

      def check(result)
        raise "Parallel renderer failed: #{status}" unless result
        true
      end
    end
  end
end

module ModLoader
  RenderSnapshotProbe = ParallelRenderer unless const_defined?(:RenderSnapshotProbe)

  # Disabled: one boolean check per Graphics.update. Enabled: one integer
  # native call every 60 updates. Allocate/draw only when the warning changes.
  module RendererNotice
    class << self
      def clear
        @sprite.bitmap.dispose if @sprite && @sprite.bitmap && !@sprite.bitmap.disposed?
        @sprite.dispose if @sprite && !@sprite.disposed?
        @viewport.dispose if @viewport
        @sprite = @viewport = nil
        @state = nil
        @ticks = 0
      end

      def update
        @ticks ||= 0
        if @ticks > 0
          @ticks -= 1
          return
        end
        @ticks = 59
        state = ModLoader.parallel_renderer_health
        return if state == @state
        clear
        @ticks = 59
        @state = state
        return if state == 0
        messages = {1 => "Renderer: temporary fallback (effect)",
                    2 => "Renderer stopped; see Display menu",
                    3 => "Renderer: temporary fallback (memory)"}
        @viewport = ::Viewport.new(0, 0, Graphics.width, Graphics.height)
        @viewport.z = 2147483647
        @sprite = ::Sprite.new(@viewport)
        @sprite.x = @sprite.y = 8
        @sprite.bitmap = ::Bitmap.new(380, 28)
        @sprite.bitmap.font.size = 18
        @sprite.bitmap.fill_rect(0, 0, 380, 28, ::Color.new(0, 0, 0, 200))
        text = messages[state] || messages[2]
        text = ModMenu.tr(text) if defined?(ModMenu)
        @sprite.bitmap.draw_text(6, 0, 368, 28, text)
      end
    end
  end
end

if defined?(ModLoader::Lifecycle)
  ModLoader::Lifecycle.register(:cleanup, :renderer_notice, 10) { ModLoader::RendererNotice.clear }
end

if defined?(::Graphics) && Graphics.respond_to?(:update) &&
    ModLoader.respond_to?(:parallel_renderer_health)
  class << ::Graphics
    alias_method :parallel_renderer_original_update, :update
    def update(*args)
      ModLoader::RendererNotice.update if defined?(ModLoader::Display) && ModLoader::Display.renderer_notices?
      parallel_renderer_original_update(*args)
    end
  end
end

# A scene transition must not display a queued image of the previous scene.
# Waiting is restricted to these explicit transition boundaries.
if defined?(::Graphics) && ModLoader.respond_to?(:parallel_renderer_frame_barrier)
  class << ::Graphics
    alias_method :snapshot_original_freeze, :freeze
    alias_method :snapshot_original_transition, :transition
    def freeze(*args)
      ModLoader.parallel_renderer_frame_barrier
      snapshot_original_freeze(*args)
    end
    def transition(*args)
      ModLoader.parallel_renderer_frame_barrier
      snapshot_original_transition(*args)
    end
  end
end

end
