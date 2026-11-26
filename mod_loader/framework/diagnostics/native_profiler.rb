# Optional native Ruby profiler (RGSS301). No trace hook, per-frame wrapper or
# files until start. No automatic startup recording.
#
#   ModLoader::Profiler.start("mod_loader/profile-map.json", :frames => 600)
#   ModLoader::Profiler.stop        # stop early and save to the chosen path
#   ModLoader::Profiler.start       # memory only; stop, then save explicitly
#   ModLoader::Profiler.save("mod_loader/profile-battle.json")
#   ModLoader::Profiler.discard     # stop and release recording memory
#
# :max_events defaults to 500000 (~12 MB of raw events + method metadata).
# A full buffer ends recording at the next safe Graphics.update boundary.
# Output is JSON: method self/total times, frame durations, and compact events.
# Existing files are never overwritten. Profiling changes execution timings;
# compare equivalent scenes and inspect the report's limitations/counters.

$imported ||= {}
unless $imported["IDL-NativeProfiler"]
$imported["IDL-NativeProfiler"] = "1.0"

module ModLoader
  module Profiler
    class << self
      def available?
        ModLoader.respond_to?(:profiler_start)
      end

      def recording?
        available? && ModLoader.profiler_recording?
      end

      def start(path = nil, options = {})
        raise "Native profiler is unavailable in this ModLoader/RGSS build" unless available?
        raise "A profiler session is already open; stop it first" if @active
        frames = options[:frames]
        limit = options.fetch(:max_events, 500000)
        raise ArgumentError, ":frames must be a positive Integer" if frames && (!frames.is_a?(Integer) || frames <= 0)
        raise ArgumentError, "path must be a String or nil" unless path.nil? || path.is_a?(String)
        raise ArgumentError, "output file already exists" if path && File.exist?(path)
        ModLoader.profiler_start(limit)
        @path, @remaining, @active = path, frames, true
        begin
          install_frame_hook
        rescue Exception
          @active = false
          ModLoader.profiler_stop
          raise
        end
        true
      end

      # On an exception/F12, stop(false) retains data without doing file I/O.
      def stop(write = true)
        return nil unless available?
        ModLoader.profiler_stop
        @active = false
        remove_frame_hook
        path = @path
        @path = nil
        save(path) if write && path
        path
      end

      def save(path)
        raise "Native profiler is unavailable" unless available?
        stop(false) if @active
        ModLoader.profiler_save(path)
        path
      end

      def discard
        stop(false)
        ModLoader.profiler_discard if available?
        nil
      end

      def record(path = nil, options = {})
        start(path, options)
        begin
          result = yield
        rescue Exception
          stop(false)
          raise
        else
          stop
          result
        end
      end

      def frame_finished(token)
        return unless @active && @frame_token.equal?(token)
        running = ModLoader.profiler_frame
        @remaining -= 1 if @remaining
        stop if !running || (@remaining && @remaining <= 0)
      end

      def abort_recording
        stop(false) if @active
      end

      private

      def install_frame_hook
        original = Graphics.method(:update)
        token = Object.new
        @original_update, @frame_token = original, token
        singleton = class << Graphics; self; end
        singleton.class_eval do
          define_method(:update) do
            begin
              result = original.call
              ModLoader::Profiler.frame_finished(token)
              result
            rescue Exception
              ModLoader::Profiler.abort_recording
              raise
            end
          end
        end
        @frame_hook = Graphics.method(:update)
      end

      def remove_frame_hook
        return unless @frame_hook
        # Do not overwrite a later wrapper installed by another mod. In that
        # case its alias may still call ours; the inactive wrapper is harmless.
        if Graphics.method(:update) == @frame_hook
          singleton = class << Graphics; self; end
          singleton.send(:define_method, :update, @original_update)
        end
        @frame_hook = @frame_token = @original_update = nil
      end
    end
  end
end

# One ensure per scene-loop invocation, not per frame. F12 and uncaught Ruby
# errors must release the native hook even if they happen outside Graphics.update.
module SceneManager
  class << self
    alias native_profiler_saved_run run
    def run
      native_profiler_saved_run
    ensure
      ModLoader::Profiler.abort_recording
    end
  end
end

end
