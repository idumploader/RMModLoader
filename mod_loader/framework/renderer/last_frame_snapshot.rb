# Completed screen image for menu backgrounds. Ordinary snap_to_bitmap still
# captures the current tree (effects and map exporters depend on that contract).
$imported ||= {}
unless $imported['ModLoader-LastFrameSnapshot']
  $imported['ModLoader-LastFrameSnapshot'] = true

  module ModLoader
    module LastFrameSnapshot
      class << self
        def available?
          ModLoader.respond_to?(:last_frame_copy) && ModLoader.respond_to?(:last_frame_enable)
        end

        def settings
          if defined?(ModLoader::Display)
            ModLoader::Display.settings
          else
            ModLoader.nvram.section(:display)
          end
        end

        def enabled?; settings[:last_frame_menu_background] != false; end

        def enabled=(value)
          return false unless available? && ModLoader.last_frame_enable(!!value)
          settings[:last_frame_menu_background] = !!value
          settings.commit
          true
        end

        def restore
          available? && ModLoader.last_frame_enable(enabled?)
        end
      end
    end
  end

  class << Graphics
    def last_frame_to_bitmap
      return snap_to_bitmap unless ModLoader::LastFrameSnapshot.available? && ModLoader::LastFrameSnapshot.enabled?
      bitmap = Bitmap.new(width, height)
      begin
        return bitmap if ModLoader.last_frame_copy(bitmap)
      rescue Exception
        bitmap.dispose unless bitmap.disposed?
        raise
      end
      bitmap.dispose
      snap_to_bitmap
    end

    # Preserve the game's existing snapshot wrappers, blur and disposal logic.
    alias_method :last_frame_original_snap_to_bitmap, :snap_to_bitmap
    def snap_to_bitmap(*args)
      if @last_frame_menu_snapshot && args.empty?
        # Avoid recursively taking the menu route on a cache miss.
        previous = @last_frame_menu_snapshot
        @last_frame_menu_snapshot = false
        begin
          last_frame_to_bitmap
        ensure
          @last_frame_menu_snapshot = previous
        end
      else
        last_frame_original_snap_to_bitmap(*args)
      end
    end

    def with_last_frame_menu_snapshot
      previous = @last_frame_menu_snapshot
      @last_frame_menu_snapshot = true
      begin
        yield
      ensure
        @last_frame_menu_snapshot = previous
      end
    end
  end

  class << SceneManager
    alias_method :last_frame_original_snapshot_for_background, :snapshot_for_background
    def snapshot_for_background
      return last_frame_original_snapshot_for_background unless ModLoader::LastFrameSnapshot.enabled?
      Graphics.with_last_frame_menu_snapshot do
        last_frame_original_snapshot_for_background
      end
    end
  end
end

# Run on reload as well as first load (F12 releases the native frame buffers).
ModLoader::LastFrameSnapshot.restore
