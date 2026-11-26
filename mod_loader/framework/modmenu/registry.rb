#==============================================================================
# ModMenu - a shared in-game settings/cheat menu any mod can plug into.
#
# One overlay menu, opened with a hotkey (default F10), that every mod registers
# entries into. Entries are grouped into category tabs (Q/E to switch) and come
# in a few kinds:
#
#   * submenu - a declarative collection of the same item types
#   * window - opens a child ModMenu_CommandWindow from a factory block
#   * action - runs a block on Enter
#   * toggle - an ON/OFF flag
#   * slider - an integer with a min/max/step, adjusted with Left/Right
#   * choice - cycles a fixed list of values with Left/Right
#   * header - a non-selectable section label
#
# Value entries (toggle/slider/choice) persist across restarts: give them a
# :key and the value is saved into a shared ModLoader.nvram section (:modmenu)
# and restored on the next launch. The whole section is committed when the menu
# closes. An entry can instead drive live game state with :get / :set procs
# (with or without a :key), and react to edits with :on_change.
#
# --- Registering entries (call at load time, or any time at runtime) ---
#
#   M = ModLoader::ModMenu
#
#   M.header("Combat", :category => "Cheats")
#   M.toggle("God mode", :category => "Cheats", :key => "mymod.god",
#            :default => false, :on_change => proc { |on| $game_temp.god = on })
#   M.slider("Game speed", :category => "Cheats", :key => "mymod.speed",
#            :default => 1, :min => 1, :max => 8, :step => 1,
#            :format => proc { |v| "x#{v}" })
#   M.choice("Difficulty", :category => "Cheats", :key => "mymod.diff",
#            :values => [:easy, :normal, :hard], :default => :normal)
#   M.action("Full heal", :category => "Cheats") { $game_party.members.each { |a| a.recover_all } }
#
#   # M.category("General", :id => :my_mod) { |tab| tab.submenu(...) { ... } }
#   M.submenu("Display", :category => "General") do |menu|
#     menu.header("Markers")
#     menu.toggle("Names", :key => "show_names", :default => true)
#     menu.slider("Size", :key => "marker_size", :default => 16,
#                 :min => 8, :max => 32, :step => 2)
#     menu.submenu("Advanced") { |child| child.action("Reset") { reset_markers } }
#   end
#   # Dynamic menus: :refresh => proc { content_version }, :valid => proc { active? }.
#   # Their builder runs on open and when the key/language changes. Use :id for
#   # stable selection and :get/:set or :key for values across rebuilds.
#   # :enabled accepts a Boolean or proc. :translate => false is for user names.
#   # :color changes only the label: :destructive (palette red) or a Color.
#   # Disabled labels are dimmed; headers keep their usual full brightness.
#   # M.action("Reset", :color => :destructive) { reset_settings }
#   # M.action("Highlight", :color => Color.new(120, 180, 255)) { highlight }
#   # :description is an optional I18n key/literal (or proc returning one), shown
#   # below the menu for the focused item. Keep it to three short lines.
#   # Actions: :close_after => true closes this window; :all closes the menu.
#   # Returning false from an action signals failure and keeps the window open.
#   # M.window remains available for custom ModMenu_CommandWindow subclasses.
#
#   # read a persisted value back anywhere:
#   ModLoader::ModMenu[ "mymod.speed" ]      # => 4
#
# Navigation: Up/Down move, Left/Right adjust, Q/E (or PageUp/PageDown) switch
# tab, Enter activates, Esc closes. Game input is blocked while open;
# the scene and network keep updating.
# Child windows share that input capture and return to their parent on Escape.
# The root remembers its last category and each category's selection/scroll.
# Navigation is persisted with settings on close; item :id survives renaming.
#
# Dependencies: ModLoader::Keyboard (7), ModLoaderNVRAM (9), ModLoader input API
#               (input_trigger?/input_repeat?). Loads after them (index 10), so
#               every feature script (400+) can register during its own load.
#==============================================================================

# Internal ModMenu component; load through modmenu/bootstrap.rb.
module ModLoader
module ModMenu
  #--------------------------------------------------------------------------
  # Registry + public API.
  #--------------------------------------------------------------------------
  class << self
    # The shared persisted-values section. Committed on menu close.
    def section
      @section ||= ModLoader.nvram.section(:modmenu, {})
    end

    def navigation; section[:navigation] || {}; end

    def remember_position(category, item_id, top_row)
      positions = (navigation[:positions] || {}).merge(
        category => { :item => item_id, :top_row => top_row })
      # Section tracks changes against a shallow snapshot. Replace the nested
      # hashes instead of mutating the stored object, so commit sees navigation.
      section[:navigation] = { :category => category, :positions => positions }
    end

    # Read a persisted entry value by its :key (nil if never set).
    def [](key); section[key]; end

    def categories; @categories ||= []; end
    def items_for(category); (@items ||= {})[category] || []; end
    def empty?; (@items ||= {}).all? { |_cat, list| list.empty? }; end

    # The open hotkey (a ModLoader::Keyboard VK). Persisted so a user remap
    # survives restarts.
    def hotkey; ModLoader.nvram[:modmenu_hotkey] || DEFAULT_HOTKEY; end
    def hotkey=(vk); ModLoader.nvram[:modmenu_hotkey] = vk; end

    # Whether a root menu (including its children) is currently open.
    def active?; @active ||= false; end

    def input_blocked?; ModLoader::InputCapture.blocked?; end

    # Low-level: append a prebuilt Item to a category (creating the tab on first
    # use, preserving registration order).
    def register(item, category = DEFAULT_CATEGORY)
      category ||= DEFAULT_CATEGORY
      @items ||= {}
      unless @items.key?(category)
        @items[category] = []
        categories << category
        register_text(category)   # tab name is translatable too
      end
      @items[category] << item
      item
    end

    # Replace this owner's contribution, leaving other mods in the category.
    # Use distinct :id values when several builders contribute to the same tab.
    def category(name, opts = {})
      builder = CategoryItems.new
      yield builder
      @category_groups ||= {}
      key = [name, opts[:id] || name]
      previous = @category_groups[key] || []
      list = items_for(name)
      list.reject! { |item| previous.include?(item) }
      builder.items.each { |item| register(item, name) }
      @category_groups[key] = builder.items
      builder
    end

    def reset_registry
      @root_window.dispose if @root_window && !@root_window.disposed?
      on_close if active?
      @items, @categories, @category_groups = {}, [], {}
      @section = nil
    end

    include EntryRegistration

    # Resolve displayed text through I18n (11) when present. The text doubles as
    # the translation key; an untranslated string comes back unchanged. Pass a
    # +default+ to register it on first use (for the menu's own built-in strings).
    # Safe before I18n loads (ModMenu is index 10, I18n is 11): falls back to the
    # literal until I18n exists, which is always true by draw time.
    def tr(text, default = nil)
      return (default || text) unless defined?(ModLoader::I18n)
      default ? ModLoader::I18n.t(text, default) : ModLoader::I18n[text]
    end

    # The active UI language (nil when I18n isn't loaded) - used to detect a
    # switch and re-translate the open menu.
    def language
      defined?(ModLoader::I18n) ? ModLoader::I18n.language : nil
    end

    # Register a displayed string as an I18n key (default = itself), so it shows
    # up in dump_templates for translators. No-op until I18n loads; harmless to
    # call repeatedly (define keeps the first default).
    def register_text(text)
      ModLoader::I18n.define(text, text) if defined?(ModLoader::I18n)
      text
    end

  end
end # module ModMenu
end # module ModLoader
