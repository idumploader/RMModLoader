# Internal ModMenu component; load through modmenu/bootstrap.rb.
module ModLoader
module ModMenu
  class << self
    # Called by the root on open/dispose to capture and release input.
    def on_open(window = nil)
      @root_window = window
      return if @active
      return false unless ModLoader::InputCapture.acquire(:menu)
      @active = true
      true
    end

    def on_close
      return unless @active
      @root_window.remember_position if @root_window && !@root_window.disposed?
      @active = false
      @root_window = nil
      ModLoader::InputCapture.release(:menu)
      section.commit                       # one write-through for all edits
    end
  end
end # module ModMenu
end # module ModLoader

#==============================================================================
# Scene integration. The menu is a scene ivar, so the engine updates it
# (update_all_windows) and disposes it on scene change (dispose_all_windows) for
# free - we only toggle it on the hotkey, dispose it once it asks to close, and
# thaw input if the scene tears down while the menu is open.
#==============================================================================
class Scene_Base
  alias modmenu_orig_update_basic update_basic
  alias modmenu_orig_terminate terminate

  def update_basic
    modmenu_orig_update_basic
    if @modmenu_window && !@modmenu_window.disposed? && @modmenu_window.closing
      modmenu_dispose_window
    end
  end

  def terminate
    ModLoader::ModMenu.on_close if ModLoader::ModMenu.active?
    modmenu_orig_terminate       # dispose_all_windows disposes the menu (+ header)
  end

  def modmenu_update_hotkey
    return if ModLoader::ModMenu.empty?
    return if @modmenu_window && @modmenu_window.closing
    if @modmenu_window && !@modmenu_window.disposed? && !@modmenu_window.closing
      @modmenu_window.request_close   # same hotkey toggles it shut
    else
      modmenu_open_window
    end
  end

  def modmenu_open_window
    return unless ModLoader::InputCapture.acquire(:menu)
    modmenu_dispose_window if @modmenu_window && !@modmenu_window.disposed?
    @modmenu_window = ModMenu_ListWindow.new
  end

  def modmenu_dispose_window
    return unless @modmenu_window
    ModLoader::ModMenu.on_close if ModLoader::ModMenu.active?
    @modmenu_window.dispose unless @modmenu_window.disposed?
    @modmenu_window = nil
  end
end

ModLoader::Hotkeys.register(:menu,
  :key => proc { ModLoader::ModMenu.hotkey }, :capture => :menu
) { |scene| scene.modmenu_update_hotkey }
ModLoader::Hotkeys.on_reset(:menu) { ModLoader::ModMenu.on_close }

if defined?(ModResetter) && ModResetter.respond_to?(:before_reload)
  ModResetter.before_reload(:modmenu) { ModLoader::ModMenu.reset_registry }
end
