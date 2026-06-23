#==============================================================================
# ModMenu - a shared in-game settings/cheat menu any mod can plug into.
#
# One overlay menu, opened with a hotkey (default F10), that every mod registers
# entries into. Entries are grouped into category tabs (Q/E to switch) and come
# in a few kinds:
#
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
#   # read a persisted value back anywhere:
#   ModLoader::ModMenu[ "mymod.speed" ]      # => 4
#
# Navigation: Up/Down move, Left/Right adjust, Q/E (or PageUp/PageDown) switch
# tab, Enter activates, Esc closes. While open the game is frozen, so the menu
# is safe to pop up on the map, in battle, or in a menu scene.
#
# Dependencies: ModLoader::Keyboard (7), ModLoaderNVRAM (9), ModLoader input API
#               (input_trigger?/input_repeat?). Loads after them (index 10), so
#               every feature script (400+) can register during its own load.
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModMenu"]
$imported["IDL-ModMenu"] = "1.0"

module ModLoader
module ModMenu
  DEFAULT_CATEGORY = "General"
  DEFAULT_HOTKEY   = ModLoader::Keyboard::F10

  #--------------------------------------------------------------------------
  # Entry kinds. Each knows how to draw itself into a window row and how to
  # react to Enter / Left / Right. The window stays dumb; entries own behaviour.
  #--------------------------------------------------------------------------

  # Base entry: a plain selectable label (rarely used directly).
  class Item
    attr_reader :label

    def initialize(label, opts = {})
      @label = label.to_s
      @opts  = opts
    end

    def selectable?; true;  end

    # Draw one row. +window+ is the ModMenu_ListWindow, +rect+ its text rect.
    def draw(window, rect)
      window.reset_font_settings
      window.draw_text(rect, @label, 0)
    end

    def on_ok(window);    end
    def on_left(window);  end
    def on_right(window); end
  end

  # A non-selectable section heading.
  class HeaderItem < Item
    def selectable?; false; end

    def draw(window, rect)
      window.change_color(window.system_color)
      window.draw_text(rect, @label, 1)
      window.change_color(window.normal_color)
    end
  end

  # Runs a block on Enter. :close_after => true closes the menu afterwards.
  class ActionItem < Item
    def initialize(label, opts, block)
      super(label, opts)
      @block = block
    end

    def on_ok(window)
      @block.call if @block
      window.request_close if @opts[:close_after]
    end
  end

  # Shared value plumbing for toggle/slider/choice: resolves the current value
  # from :get / the NVRAM section / :default, and writes back through :set, the
  # section, and :on_change.
  class ValueItem < Item
    def initialize(label, opts)
      super(label, opts)
      @value = load_value
    end

    def key; @opts[:key]; end

    def value
      @opts[:get] ? @opts[:get].call : @value
    end

    def value=(new_value)
      @value = new_value
      @opts[:set].call(new_value)        if @opts[:set]
      ModMenu.section[key] = new_value    if key
      @opts[:on_change].call(new_value)   if @opts[:on_change]
      new_value
    end

    def draw(window, rect)
      window.reset_font_settings
      window.draw_text(rect, @label, 0)
      vrect = rect.clone
      vrect.width -= 4
      draw_value(window, vrect)
    end

    # Override per kind. Default: plain right-aligned string.
    def draw_value(window, rect)
      window.draw_text(rect, value.to_s, 2)
    end

    private

    def load_value
      if @opts[:get]
        @opts[:get].call
      elsif key && ModMenu.section.key?(key)
        ModMenu.section[key]
      else
        @opts[:default]
      end
    end
  end

  # ON/OFF flag. Enter or Left/Right flips it.
  class ToggleItem < ValueItem
    def on_ok(window);    flip(window); end
    def on_left(window);  flip(window); end
    def on_right(window); flip(window); end

    def draw_value(window, rect)
      window.draw_inline_options(rect, [off_text, on_text], value ? 1 : 0)
    end

    private

    def flip(window); self.value = !value; end
    def on_text;  @opts[:on_text]  || "ON";  end
    def off_text; @opts[:off_text] || "OFF"; end
  end

  # Integer in [min, max], stepped by Left/Right. Drawn as a gradient gauge plus
  # the value text. Colour pair via :gauge => [c1, c2] (palette index or Color).
  class SliderItem < ValueItem
    def on_left(window);  step(-1); end
    def on_right(window); step(+1); end

    def draw_value(window, rect)
      window.draw_slider(rect, rate, gauge_colors(window), formatted)
    end

    private

    def step(dir)
      lo, hi, st = min, max, @opts[:step] || 1
      self.value = [[value + dir * st, lo].max, hi].min
    end

    def min; @opts[:min] || 0;   end
    def max; @opts[:max] || 100; end

    def rate
      lo, hi = min, max
      return 0.0 if hi == lo
      r = (value - lo).to_f / (hi - lo)
      r < 0 ? 0.0 : (r > 1 ? 1.0 : r)
    end

    def gauge_colors(window)
      g = @opts[:gauge]
      if g.is_a?(Array) && g.size == 2
        [window.menu_color(g[0]), window.menu_color(g[1])]
      else
        [window.mp_gauge_color1, window.mp_gauge_color2]   # blue by default
      end
    end

    def formatted
      @opts[:format] ? @opts[:format].call(value) : value.to_s
    end
  end

  # Cycles a fixed list of values (wraps). Optional parallel :labels for display.
  class ChoiceItem < ValueItem
    def on_left(window);  cycle(-1); end
    def on_right(window); cycle(+1); end

    def draw_value(window, rect)
      list = values
      return if list.empty?
      cur = list.index(value) || 0
      window.draw_inline_options(rect, (0...list.size).map { |i| label_at(i) }, cur)
    end

    private

    def values; @opts[:values] || []; end

    def cycle(dir)
      list = values
      return if list.empty?
      i = list.index(value) || 0
      self.value = list[(i + dir) % list.size]
    end

    def label_at(i)
      labels = @opts[:labels]
      (labels && labels[i]) ? labels[i].to_s : values[i].to_s
    end
  end

  #--------------------------------------------------------------------------
  # Registry + public API.
  #--------------------------------------------------------------------------
  class << self
    # The shared persisted-values section. Committed on menu close.
    def section
      @section ||= ModLoader.nvram.section(:modmenu, {})
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

    # Whether the menu is currently capturing input (used to freeze the game).
    def active?; @active ||= false; end

    # Low-level: append a prebuilt Item to a category (creating the tab on first
    # use, preserving registration order).
    def register(item, category = DEFAULT_CATEGORY)
      @items ||= {}
      unless @items.key?(category)
        @items[category] = []
        categories << category
      end
      @items[category] << item
      item
    end

    def header(label, opts = {})
      register(HeaderItem.new(label, opts), opts[:category] || DEFAULT_CATEGORY)
    end

    def action(label, opts = {}, &block)
      register(ActionItem.new(label, opts, block), opts[:category] || DEFAULT_CATEGORY)
    end

    def toggle(label, opts = {})
      register(ToggleItem.new(label, opts), opts[:category] || DEFAULT_CATEGORY)
    end

    def slider(label, opts = {})
      register(SliderItem.new(label, opts), opts[:category] || DEFAULT_CATEGORY)
    end

    def choice(label, opts = {})
      register(ChoiceItem.new(label, opts), opts[:category] || DEFAULT_CATEGORY)
    end

    # Called by the window on open/close to freeze and thaw the game.
    def on_open
      @active = true
      $executor_input_is_disabled = true   # also mute executor binds / give popup
    end

    def on_close
      @active = false
      $executor_input_is_disabled = false
      section.commit                       # one write-through for all edits
    end
  end
end # module ModMenu
end # module ModLoader

#==============================================================================
# Freeze the game's own input while the menu is up. The menu itself navigates
# via ModLoader.input_* (raw VK), so nulling RPG Maker's Input never starves it.
# Composes with ExecutorScene's Input override when both are loaded.
#==============================================================================
module Input
  class << self
    alias modmenu_orig_trigger? trigger?
    alias modmenu_orig_press?   press?
    alias modmenu_orig_repeat?  repeat?
    alias modmenu_orig_dir4     dir4
    alias modmenu_orig_dir8     dir8
  end

  def self.trigger?(key); ModLoader::ModMenu.active? ? false : modmenu_orig_trigger?(key); end
  def self.press?(key);   ModLoader::ModMenu.active? ? false : modmenu_orig_press?(key);   end
  def self.repeat?(key);  ModLoader::ModMenu.active? ? false : modmenu_orig_repeat?(key);  end
  def self.dir4; ModLoader::ModMenu.active? ? 0 : modmenu_orig_dir4; end
  def self.dir8; ModLoader::ModMenu.active? ? 0 : modmenu_orig_dir8; end
end

#==============================================================================
# Header window - the category tab line plus a one-line key hint. Passive: it
# never reads input, the list window just calls #set on it.
#==============================================================================
class ModMenu_HeaderWindow < Window_Base
  def initialize(x, y, width)
    super(x, y, width, fitting_height(2))
  end

  def set(category, index, count)
    contents.clear
    change_color(system_color)
    title = count > 1 ? "<<  #{category}  >>   (#{index + 1}/#{count})" : category.to_s
    draw_text(0, 0, contents.width, line_height, title, 1)
    contents.font.size -= 4
    draw_text(0, line_height, contents.width, line_height,
              "WASD/Arrows move+adjust   Q/E tab   Enter ok   Esc close", 1)
    reset_font_settings
  end
end

#==============================================================================
# The list window. A real Window_Command, so cursor movement, scrolling, the
# blinking cursor, item drawing and the sound cues all come from the engine. We
# only override the two input methods to read ModLoader.input_* (raw VK) instead
# of Input - because the menu nulls Input to freeze the rest of the game, and a
# native Window_Selectable would otherwise have nothing to navigate with.
#
# Lifecycle: stored as a Scene_Base ivar, so the engine auto-updates it via
# update_all_windows and auto-disposes it via dispose_all_windows on scene
# change. It owns the header window and disposes it in #dispose.
#==============================================================================
class ModMenu_ListWindow < Window_Command
  K = ModLoader::Keyboard

  attr_reader :closing

  def initialize
    @cat_index = 0
    @closing   = false
    super(menu_x, menu_y)        # Window_Command#initialize: builds list, activates
    self.z = 2000
    create_header
    select_first_enabled
    refresh_header
    ModLoader::ModMenu.on_open
  end

  #--- geometry (called from inside super, so depend only on Graphics) ---
  def window_width;  (Graphics.width * 0.8).to_i; end
  def visible_line_number; [(Graphics.height * 0.6).to_i / line_height, 1].max; end
  def header_height; fitting_height(2); end
  def menu_x; (Graphics.width  - window_width) / 2; end
  def menu_y; (Graphics.height - (window_height + header_height)) / 2 + header_height; end

  def category; ModLoader::ModMenu.categories[@cat_index]; end

  #--- list contents ---
  def make_command_list
    ModLoader::ModMenu.items_for(category).each do |item|
      add_command(item.label, :entry, item.selectable?, item)
    end
  end

  # Delegate row drawing to the entry (handles its own label + value + colour).
  def draw_item(index)
    item = @list[index][:ext]
    item.draw(self, item_rect_for_text(index)) if item
  end

  #--------------------------------------------------------------------------
  # Shared value renderers (called by entries, only on (re)draw - never per
  # frame). draw_gauge / gradient_fill_rect are native Window_Base.
  #--------------------------------------------------------------------------
  INLINE_GAP = 16   # px between inline option labels

  # Accept a palette index (Integer) or a Color; return a Color.
  def menu_color(c)
    c.is_a?(Integer) ? text_color(c) : c
  end

  # A gradient gauge filling the right portion of +rect+, with +text+ at the far
  # right. +rate+ is 0.0..1.0.
  def draw_slider(rect, rate, colors, text)
    c1, c2 = colors
    tw  = contents.text_size(text).width
    gx  = rect.x + (rect.width * 0.45).to_i
    gw  = rect.width - (gx - rect.x) - tw - 12
    draw_gauge(gx, rect.y, [gw, 1].max, rate, c1, c2)
    draw_text(rect, text, 2)
  end

  # All options on one line, right-aligned as a block: the current one is bright,
  # the rest dimmed. Falls back to "<  current  >" when the block won't fit.
  def draw_inline_options(rect, labels, current)
    total = labels.inject(0) { |w, s| w + contents.text_size(s).width }
    total += (labels.size - 1) * INLINE_GAP
    if total <= rect.width * 0.6
      x = rect.x + rect.width - total
      labels.each_with_index do |s, i|
        change_color(normal_color, i == current)
        w = contents.text_size(s).width
        draw_text(x, rect.y, w + 2, rect.height, s, 0)
        x += w + INLINE_GAP
      end
      change_color(normal_color)
    else
      change_color(normal_color)
      draw_text(rect, "<  #{labels[current]}  >", 2)
    end
  end

  def create_header
    @header = ModMenu_HeaderWindow.new(x, y - header_height, width)
    @header.z = z
  end

  def refresh_header
    @header.set(category, @cat_index, ModLoader::ModMenu.categories.size)
  end

  def dispose
    super
    @header.dispose if @header && !@header.disposed?
  end

  def request_close
    return if @closing
    @closing = true
    deactivate
    ModLoader::ModMenu.on_close
  end

  #--------------------------------------------------------------------------
  # Input - overridden to read raw VK (Input itself is nulled while we're up).
  # Up/Down skip non-selectable headers; Left/Right adjust value entries.
  #--------------------------------------------------------------------------
  # The game remaps WASD->arrows at the engine Input layer; we read raw VK, so
  # accept both arrows and WASD here.
  def vk_down?(*vks);   vks.any? { |vk| ModLoader.input_repeat?(vk) }; end
  def vk_pressed?(*vks); vks.any? { |vk| ModLoader.input_trigger?(vk) }; end

  def process_cursor_move
    return unless cursor_movable?
    last = @index
    move_index(+1) if vk_down?(K::DOWN, K::S)
    move_index(-1) if vk_down?(K::UP,   K::W)
    Sound.play_cursor if @index != last
  end

  def move_index(dir)
    return if item_max == 0
    i = @index
    item_max.times do
      i = (i + dir) % item_max
      break if command_enabled?(i)
    end
    select(i) if command_enabled?(i)
  end

  def process_handling
    return unless open? && active
    return switch_category(+1) if vk_pressed?(K::E, K::NEXT)
    return switch_category(-1) if vk_pressed?(K::Q, K::PRIOR)
    return request_close       if vk_pressed?(K::ESC)

    item = current_ext
    return unless item && command_enabled?(@index)
    if vk_pressed?(K::RETURN, K::SPACE)
      item.on_ok(self)
      Sound.play_ok
      redraw_current_item unless disposed? || @closing
    elsif vk_down?(K::RIGHT, K::D)
      item.on_right(self); Sound.play_cursor; redraw_current_item
    elsif vk_down?(K::LEFT, K::A)
      item.on_left(self);  Sound.play_cursor; redraw_current_item
    end
  end

  def switch_category(dir)
    cats = ModLoader::ModMenu.categories
    return if cats.size <= 1
    @cat_index = (@cat_index + dir) % cats.size
    refresh                # Window_Command: rebuild list + create_contents + redraw
    self.top_row = 0
    select_first_enabled
    refresh_header
    Sound.play_cursor
  end

  def select_first_enabled
    i = (0...item_max).find { |k| command_enabled?(k) }
    select(i || 0)
  end
end

#==============================================================================
# Scene integration. The menu is a scene ivar, so the engine updates it
# (update_all_windows) and disposes it on scene change (dispose_all_windows) for
# free - we only toggle it on the hotkey, dispose it once it asks to close, and
# thaw input if the scene tears down while the menu is open.
#==============================================================================
class Scene_Base
  alias modmenu_orig_update    update
  alias modmenu_orig_terminate terminate

  def update
    modmenu_orig_update          # update_all_windows already ran @modmenu_window
    modmenu_update_hotkey
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
    return unless ModLoader.input_trigger?(ModLoader::ModMenu.hotkey)
    if @modmenu_window && !@modmenu_window.disposed? && @modmenu_window.active
      @modmenu_window.request_close   # same hotkey toggles it shut
    else
      modmenu_open_window
    end
  end

  def modmenu_open_window
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

end # not $imported["IDL-ModMenu"]
