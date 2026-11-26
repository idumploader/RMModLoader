# Ordered, keyed callbacks survive RGSS F12 without wrapping game classes.
$imported ||= {}
unless $imported['IDL-ModLoaderLifecycle']
  $imported['IDL-ModLoaderLifecycle'] = '1.0'
  module ModLoader
    module Lifecycle
      class << self
        def register(phase, key, priority = 0, &callback)
          raise ArgumentError, 'Unknown lifecycle phase' unless [:before_run, :cleanup].include?(phase)
          raise ArgumentError, 'Expected lifecycle callback' unless callback
          @callbacks ||= {}
          @callbacks[phase] ||= {}
          @callbacks[phase][key] = [priority, key.to_s, callback]
          true
        end
        def before_run
          callbacks(:before_run).each { |entry| entry[2].call }
        end
        def cleanup
          failure = nil
          callbacks(:cleanup).each do |entry|
            begin
              entry[2].call
            rescue Exception => error
              failure ||= error
            end
          end
          raise failure if failure
        end
        private
        def callbacks(phase)
          ((@callbacks || {})[phase] || {}).values.sort_by { |entry| entry[0, 2] }
        end
      end
    end
    Lifecycle.register(:cleanup, :native_renderer, 20) do
      ModLoader.parallel_renderer_finish if ModLoader.respond_to?(:parallel_renderer_finish)
    end
    Lifecycle.register(:cleanup, :native_glyph_cache, 30) do
      ModLoader.glyph_cache_clear if ModLoader.respond_to?(:glyph_cache_clear)
    end
  end
end
