# Menu-only bitmap blur and transition duration controls.
$imported ||= {}
unless $imported['ModLoader-MenuRendering']
  $imported['ModLoader-MenuRendering'] = true
  module ModLoader
    module MenuRendering
      class << self
        attr_accessor :previous_scene_class
        def reset
          @previous_scene_class = nil
          @background = @transition = false
        end
        def settings
          defined?(ModLoader::Display) ? ModLoader::Display.settings : ModLoader.nvram.section(:display)
        end
        def blur_available?; ModLoader.respond_to?(:menu_bitmap_blur); end
        def fast_blur?; settings[:fast_menu_blur] != false; end
        def fast_blur=(value)
          settings[:fast_menu_blur] = !!value
          settings.commit
        end
        def transition_mode
          value = settings[:menu_transition_mode]
          [:normal, :fast, :off].include?(value) ? value : :normal
        end
        def transition_mode=(value)
          return false unless [:normal, :fast, :off].include?(value)
          settings[:menu_transition_mode] = value
          settings.commit
          true
        end
        def background?; !!@background; end
        def transition?; !!@transition; end
        def with_background
          previous = @background
          @background = true
          begin; yield; ensure; @background = previous; end
        end
        def with_transition
          previous = @transition
          @transition = true
          begin; yield; ensure; @transition = previous; end
        end
        def menu_class?(klass)
          klass && klass <= Scene_MenuBase
        end
        def menu_transition?(scene)
          menu_class?(scene.class) ||
            ((scene.is_a?(Scene_Map) || scene.is_a?(Scene_Title)) && menu_class?(previous_scene_class))
        end
        def duration(original)
          return original unless transition? && original.is_a?(Integer) && original > 0
          case transition_mode
          when :fast; (original + 1) / 2
          when :off; 0
          else; original
          end
        end
      end
    end
  end

  if defined?(ModLoader::Lifecycle)
    ModLoader::Lifecycle.register(:before_run, :menu_rendering, 30) { ModLoader::MenuRendering.reset }
  end

  class Bitmap
    alias_method :menu_rendering_original_blur, :blur
    def blur
      control = ModLoader::MenuRendering
      if control.background? && control.fast_blur? && control.blur_available?
        return nil if ModLoader.menu_bitmap_blur(self)
      end
      menu_rendering_original_blur
    end
  end

  class << SceneManager
    alias_method :menu_rendering_original_snapshot, :snapshot_for_background
    def snapshot_for_background
      ModLoader::MenuRendering.with_background { menu_rendering_original_snapshot }
    end
  end

  class Scene_Base
    alias_method :menu_rendering_original_pre_terminate, :pre_terminate
    def pre_terminate
      ModLoader::MenuRendering.previous_scene_class = self.class
      menu_rendering_original_pre_terminate
    end
    alias_method :menu_rendering_original_perform_transition, :perform_transition
    def perform_transition
      control = ModLoader::MenuRendering
      return menu_rendering_original_perform_transition unless control.menu_transition?(self)
      control.with_transition { menu_rendering_original_perform_transition }
    end
  end

  class << Graphics
    alias_method :menu_rendering_original_transition, :transition
    def transition(*args)
      # Restrict to the ordinary crossfade; masked/event/battle effects keep
      # their original timing, including explicit transition(0) setup calls.
      if !args.empty? && (args.size < 2 || args[1].nil? || args[1] == '')
        args[0] = ModLoader::MenuRendering.duration(args[0])
      end
      menu_rendering_original_transition(*args)
    end
  end
end
# Previous run's scene classes must not leak through F12 script reload.
ModLoader::MenuRendering.reset
