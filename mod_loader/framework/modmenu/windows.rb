# Internal ModMenu component; load through modmenu/bootstrap.rb.
# A solid backing prevents transparent pixels in the game's skin from revealing
# other menu text. A child's shade sits between parent and child, including at
# deeper nesting levels. Each owner releases its sprites and the shared pixel.
class ModMenu_Backdrop
  def initialize(window)
    @window = window
    @pixel = Bitmap.new(1, 1)
    @pixel.fill_rect(0, 0, 1, 1, Color.new(0, 0, 0, 255))
    @panel = Sprite.new
    @panel.bitmap = @pixel
    update
  end

  def dim_parent
    @shade = Sprite.new
    @shade.bitmap = @pixel
    @shade.opacity = 144
    update
  end

  def update
    visible = @window.visible && @window.openness > 0
    inset = 4
    @panel.x = @window.x + inset
    panel_height = [@window.height - inset * 2, 1].max * @window.openness / 255
    @panel.y = @window.y + (@window.height - panel_height) / 2
    @panel.zoom_x = [@window.width - inset * 2, 1].max
    @panel.zoom_y = panel_height
    @panel.z = @window.z - 1
    @panel.opacity = @window.opacity
    @panel.visible = visible
    if @shade
      @shade.zoom_x, @shade.zoom_y = Graphics.width, Graphics.height
      @shade.z = @window.z - 2
      @shade.visible = visible
    end
  end

  def dispose
    @shade.dispose if @shade
    @panel.dispose
    @pixel.dispose
  end
end

# ModMenu has its own restrained scale, independent of game-specific HUD fixes.
module ModLoader::ModMenu
  def self.ui_scale
    resolution = [[Graphics.width / 640.0, Graphics.height / 480.0].min, 1.0].max
    [1.0 + (resolution - 1.0) * 0.2, 25.0 / 22.0].min
  end
  def self.ui_pixels(value); (value * ui_scale).round; end
end
module ModMenu_WindowMetrics
  def create_contents
    super
    reset_font_settings
  end
  def line_height; ModLoader::ModMenu.ui_pixels(super); end
  def standard_padding; ModLoader::ModMenu.ui_pixels(super); end
  def reset_font_settings(*args)
    super(*args)
    if ModLoader::ModMenu.ui_scale > 1.0
      contents.font.size = [ModLoader::ModMenu.ui_pixels(contents.font.size), 25].min
    end
  end
end

# Passive menu panels keep their backing with them; the root owns their lifetime.
class ModMenu_PanelWindow < Window_Base
  include ModMenu_WindowMetrics
  def initialize(*args)
    super
    self.back_opacity = 255
    @backdrop = ModMenu_Backdrop.new(self)
  end

  def update
    super
    @backdrop.update
  end

  def dispose
    return if disposed?
    @backdrop.dispose
    super
  end
end

class ModMenu_DescriptionWindow < ModMenu_PanelWindow
  LINES = 3

  def initialize(x, y, width)
    super(x, y, width, fitting_height(LINES))
  end

  def set(text)
    return if @text == text
    @text = text
    contents.clear
    reset_font_settings
    contents.font.size = [contents.font.size, ModLoader::ModMenu.ui_pixels(20)].min
    # Only one overflow line is needed to decide whether to show an ellipsis.
    # Measuring the rest of a long item description stalls held-key navigation.
    lines = wrap(text, LINES + 1)
    if lines.size > LINES
      last = lines[LINES - 1]
      last = last[0...-1] while !last.empty? && text_size(last + '...').width > contents.width
      lines[LINES - 1] = last.rstrip + '...'
    end
    lines.first(LINES).each_with_index do |line, index|
      draw_text(0, index * line_height, contents.width, line_height, line)
    end
  end

  def wrap(text, limit = nil)
    lines = []
    text.split("\n", -1).each do |paragraph|
      line = ''
      paragraph.split.each do |word|
        candidate = line.empty? ? word : line + ' ' + word
        # Measure words together; RGSS text_size is a native font operation.
        # Only an individual word wider than the panel needs character splitting.
        if text_size(candidate).width <= contents.width
          line = candidate
          next
        end
        if !line.empty?
          lines << line
          return lines if limit && lines.size >= limit
          line = ''
        end
        if text_size(word).width <= contents.width
          line = word
          next
        end
        word.each_char do |char|
          if !line.empty? && text_size(line + char).width > contents.width
            lines << line
            return lines if limit && lines.size >= limit
            line = ''
          end
          line += char
        end
      end
      lines << line
      return lines if limit && lines.size >= limit
    end
    lines
  end
end

#==============================================================================
# Header window - the category tab line plus a one-line key hint. Passive: it
# never reads input, the list window just calls #set on it.
#==============================================================================
class ModMenu_HeaderWindow < ModMenu_PanelWindow
  def initialize(x, y, width)
    super(x, y, width, fitting_height(2))
  end

  def set(category, index, count)
    contents.clear
    change_color(system_color)
    name  = ModLoader::ModMenu.tr(category.to_s)
    title = count > 1 ? "<<  #{name}  >>   (#{index + 1}/#{count})" : name
    draw_text(0, 0, contents.width, line_height, title, 1)
    contents.font.size -= ModLoader::ModMenu.ui_pixels(4)
    hint = ModLoader::ModMenu.tr("modmenu.hint",
             "WASD/Arrows move+adjust   Q/E tab   Enter ok   Esc close")
    draw_text(0, line_height, contents.width, line_height, hint, 1)
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
# Shared modal command window. Only the scene-owned root is auto-updated by
# RGSS; each parent owns, updates and disposes its one child explicitly.
class ModMenu_CommandWindow < Window_Command
  include ModMenu_WindowMetrics
  K = ModLoader::Keyboard
  attr_reader :closing, :child_window, :parent_window

  def initialize(x = 0, y = 0)
    @closing = false
    @input_armed = false
    super(x, y)
    self.back_opacity = 255
    @backdrop = ModMenu_Backdrop.new(self)
  end

  def input_ready?
    active && open? && !@closing && @input_armed
  end

  def arm_input
    @input_armed = false
  end

  def input_held?
    [K::RETURN, K::SPACE, K::ESC, K::UP, K::DOWN, K::LEFT, K::RIGHT,
     K::W, K::A, K::S, K::D, K::Q, K::E, K::NEXT, K::PRIOR,
     ModLoader::ModMenu.hotkey].any? { |key| ModLoader.input_press?(key) }
  end

  def update
    return if disposed? || @closing
    @input_armed = true if active && !@input_armed && !input_held?
    # A child created during super must not see the key which opened it.
    child = @child_window
    super
    if child && child.equal?(@child_window)
      child.update unless child.disposed? || child.closing
      close_child if child.disposed? || child.closing
    end
    @backdrop.update unless disposed?
  end

  def open_child(window)
    return unless window
    raise ArgumentError, "expected a ModMenu_CommandWindow" unless window.is_a?(ModMenu_CommandWindow)
    raise ArgumentError, "window already owned or closed" if window.parent_window || window.disposed? || window.closing
    raise ArgumentError, "a child window is already open" if @child_window
    raise ArgumentError, "cannot open a child of a closed window" if disposed? || @closing
    ancestor = self
    while ancestor
      raise ArgumentError, "cannot attach an ancestor as a child" if window.equal?(ancestor)
      ancestor = ancestor.parent_window
    end
    @child_window = window
    window.attach_to(self)
    deactivate
    window
  end

  def attach_to(parent)
    @parent_window = parent
    self.z = parent.z + 100
    @backdrop.dim_parent
    arm_input
  end

  def menu_bottom
    @parent_window ? @parent_window.menu_bottom : Graphics.height - 12
  end

  def focused_window
    @child_window ? @child_window.focused_window : self
  end

  # Custom command windows can override this without using ModMenu::Item.
  def description_text; ''; end

  def close_child
    child, @child_window = @child_window, nil
    child.dispose if child && !child.disposed?
    unless @closing || disposed?
      activate
      arm_input
    end
  end

  def request_close
    return if @closing
    @closing = true
    deactivate
  end

  def close_menu
    @parent_window ? @parent_window.close_menu : request_close
  end

  def dispose
    return if disposed?
    @closing = true
    close_child
    @backdrop.dispose
    super
  end

  def vk_down?(*vks); vks.any? { |vk| ModLoader.input_repeat?(vk) }; end
  def vk_pressed?(*vks); vks.any? { |vk| ModLoader.input_trigger?(vk) }; end

  def process_cursor_move
    return unless input_ready? && cursor_movable?
    last = @index
    move_index(+1) if vk_down?(K::DOWN, K::S)
    move_index(-1) if vk_down?(K::UP, K::W)
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

  def select_first_enabled
    select((0...item_max).find { |i| command_enabled?(i) } || 0)
  end

  def process_handling
    return unless input_ready?
    if vk_pressed?(K::ESC)
      Sound.play_cancel
      request_close
    elsif vk_pressed?(K::RETURN, K::SPACE)
      process_ok
    end
  end
end

module ModMenu_ItemDrawing
  # RGSS text_size excludes some glyph overhang/outline pixels. Giving
  # draw_text exactly that width can trigger compression even for short labels.
  def menu_text_width(text)
    text_size(text).width + ModLoader::ModMenu.ui_pixels(4)
  end

  def description_text
    current_ext ? current_ext.description_text : ''
  end

  # Delegate row drawing to the entry (handles its own label + value + colour).
  def draw_item(index)
    item = @list[index][:ext]
    item.draw(self, item_rect_for_text(index)) if item
  end

  # Headers bound a section even when some of its rows are scrolled offscreen.
  # Other entry types do not split the shared slider columns.
  def slider_group(item)
    items = @list.map { |command| command[:ext] }
    first = items.index(item)
    last = first + 1
    first -= 1 while first > 0 && !items[first - 1].is_a?(ModLoader::ModMenu::HeaderItem)
    last += 1 while last < items.size && !items[last].is_a?(ModLoader::ModMenu::HeaderItem)
    items[first...last].select { |entry| entry.is_a?(ModLoader::ModMenu::SliderItem) }
  end

  def redraw_current_item
    return super unless current_ext.is_a?(ModLoader::ModMenu::SliderItem)
    # A custom formatter can change the shared value width. Repaint the whole
    # section's sliders together so their old gauge edges cannot remain behind.
    group = slider_group(current_ext)
    @list.each_with_index do |command, index|
      redraw_item(index) if group.include?(command[:ext])
    end
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

  # +rect+ is already the value's area, separate from the title. Draw the gauge
  # only when space remains beside the section's shared value column.
  # +rate+ is 0.0..1.0.
  def draw_slider(rect, rate, colors, text, value_width)
    c1, c2 = colors
    gw = rect.width - value_width - ModLoader::ModMenu.ui_pixels(12)
    if gw > 0
      bar_h = ModLoader::ModMenu.ui_pixels(6)
      by = rect.y + (line_height - bar_h) / 2
      contents.fill_rect(rect.x, by, gw, bar_h, gauge_back_color)
      contents.gradient_fill_rect(rect.x, by, (gw * rate).to_i, bar_h, c1, c2)
    end
    draw_text(rect, text, 2)
  end

  # All options on one line, right-aligned as a block: the current one is bright,
  # the rest dimmed. Falls back to "<  current  >" when the block won't fit.
  def draw_inline_options(rect, labels, current)
    total = labels.inject(0) { |w, s| w + menu_text_width(s) }
    total += (labels.size - 1) * ModLoader::ModMenu.ui_pixels(INLINE_GAP)
    if total <= rect.width
      x = rect.x + rect.width - total
      labels.each_with_index do |s, i|
        change_color(normal_color, i == current)
        w = menu_text_width(s)
        draw_text(x, rect.y, w, rect.height, s, 0)
        x += w + ModLoader::ModMenu.ui_pixels(INLINE_GAP)
      end
      change_color(normal_color)
    else
      change_color(normal_color)
      draw_text(rect, "<  #{labels[current]}  >", 2)
    end
  end

end

# Standard item window: no custom class needed for settings or action lists.
# :refresh => proc { comparable_key } rebuilds dynamic content on key changes.
# :valid => proc { bool } closes a child when its subject/session disappears.
class ModMenu_SubmenuWindow < ModMenu_CommandWindow
  include ModMenu_ItemDrawing
  attr_reader :definition
  def initialize(definition)
    @definition = definition
    definition.prepare
    @refresh_key = definition.refresh_key
    @lang = ModLoader::ModMenu.language
    super(0, 0)
    center_window
    select_first_enabled
  end
  def window_width
    [(@definition.opts[:width] ? ModLoader::ModMenu.ui_pixels(@definition.opts[:width]) : [(Graphics.width * 0.6).to_i, ModLoader::ModMenu.ui_pixels(800)].min), Graphics.width - 24].min
  end
  def visible_line_number
    bottom = parent_window ? menu_bottom : Graphics.height - fitting_height(ModMenu_DescriptionWindow::LINES) - 24
    [@definition.items.size, [(bottom - 12 - standard_padding * 2) / line_height, 1].max].min
  end
  def attach_to(parent)
    super
    self.height = window_height
    center_window
    refresh
    @backdrop.update
  end
  def center_window
    self.x = (Graphics.width - width) / 2
    self.y = [12, (12 + menu_bottom - height) / 2].max
  end
  def make_command_list
    @definition.items.each { |item| add_command(item.label, :entry, item.selectable?, item) }
  end
  def command_enabled?(index)
    item = @list[index] && @list[index][:ext]
    item && item.selectable?
  end
  def update
    return request_close unless @definition.valid?
    key = @definition.refresh_key
    language = ModLoader::ModMenu.language
    if key != @refresh_key || language != @lang
      selected = current_ext && current_ext.identifier
      old_top = top_row
      @definition.prepare
      @refresh_key, @lang = key, language
      self.height = window_height
      center_window
      refresh
      self.top_row = old_top
      index = @definition.items.index { |item| item.identifier == selected }
      index && command_enabled?(index) ? select(index) : select_first_enabled
    end
    super
  end
  def process_ok
    return unless current_ext && command_enabled?(@index)
    result = current_ext.on_ok(self)
    result == false ? Sound.play_buzzer : Sound.play_ok
    refresh unless disposed? || closing
  end
  def process_handling
    return unless input_ready?
    if vk_pressed?(K::ESC)
      Sound.play_cancel
      request_close
    elsif vk_pressed?(K::RETURN, K::SPACE)
      process_ok
    elsif current_ext && command_enabled?(@index)
      if vk_down?(K::LEFT, K::A)
        current_ext.on_left(self); Sound.play_cursor; refresh
      elsif vk_down?(K::RIGHT, K::D)
        current_ext.on_right(self); Sound.play_cursor; refresh
      end
    end
  end
end

class ModMenu_ListWindow < ModMenu_CommandWindow

  def initialize
    @cat_index = ModLoader::ModMenu.categories.index(ModLoader::ModMenu.navigation[:category]) || 0
    @closing   = false
    @lang      = ModLoader::ModMenu.language
    super(menu_x, menu_y)        # Window_Command#initialize: builds list, activates
    self.z = 2000
    create_header
    @description_window = ModMenu_DescriptionWindow.new(x, y + height, width)
    restore_position
    refresh_header
    refresh_description
    @header.update
    @backdrop.update
    ModLoader::ModMenu.on_open(self)
  end

  def update
    super
    if !disposed? && !closing && language_changed?
      refresh
      refresh_header
    end
    refresh_description unless disposed? || closing
  end

  #--- geometry (called from inside super, so depend only on Graphics) ---
  def window_width; [(Graphics.width * 0.8).to_i, ModLoader::ModMenu.ui_pixels(800)].min; end
  def visible_line_number
    available = Graphics.height - 24 - header_height - description_height - standard_padding * 2
    [[(Graphics.height * 0.6).to_i, available].min / line_height, 1].max
  end
  def header_height; fitting_height(2); end
  def description_height; fitting_height(ModMenu_DescriptionWindow::LINES); end
  def menu_x; (Graphics.width  - window_width) / 2; end
  def menu_y; (Graphics.height - (window_height + header_height + description_height)) / 2 + header_height; end
  def menu_bottom; y + height - 8; end

  def category; ModLoader::ModMenu.categories[@cat_index]; end

  def remember_position
    item_id = current_ext && current_ext.identifier
    ModLoader::ModMenu.remember_position(category, item_id, top_row)
  end

  def restore_position
    saved = (ModLoader::ModMenu.navigation[:positions] || {})[category]
    index = saved && @list.index { |command| command[:ext].identifier == saved[:item] }
    if index && command_enabled?(index)
      self.top_row = saved[:top_row]
      select(index) # RGSS keeps the cursor visible if rows moved since closing.
    else
      self.top_row = 0
      select_first_enabled
    end
  end

  def command_enabled?(index)
    item = @list[index] && @list[index][:ext]
    item && item.selectable?
  end

  #--- list contents ---
  def make_command_list
    ModLoader::ModMenu.items_for(category).each do |item|
      add_command(item.label, :entry, item.selectable?, item)
    end
  end

  include ModMenu_ItemDrawing

  def create_header
    @header = ModMenu_HeaderWindow.new(x, y - header_height, width)
    @header.z = z
  end

  def refresh_header
    @header.set(category, @cat_index, ModLoader::ModMenu.categories.size)
  end

  def refresh_description
    focused = focused_window
    @description_window.z = focused.z + 1
    @description_window.set(focused.description_text)
    @description_window.update
  end

  def dispose
    return if disposed?
    # Capture selection and native scroll coordinates before RGSS disposes us.
    ModLoader::ModMenu.on_close
    super
    @header.dispose if @header && !@header.disposed?
    @description_window.dispose if @description_window && !@description_window.disposed?
  end

  #--------------------------------------------------------------------------
  # Input - overridden to read raw VK (Input itself is nulled while we're up).
  # Up/Down skip non-selectable headers; Left/Right adjust value entries.
  #--------------------------------------------------------------------------
  # The game remaps WASD->arrows at the engine Input layer; we read raw VK, so
  # accept both arrows and WASD here.
  def process_handling
    return unless input_ready?
    return switch_category(+1) if vk_pressed?(K::E, K::NEXT)
    return switch_category(-1) if vk_pressed?(K::Q, K::PRIOR)
    return request_close       if vk_pressed?(K::ESC)

    item = current_ext
    return unless item && command_enabled?(@index)
    if vk_pressed?(K::RETURN, K::SPACE)
      result = item.on_ok(self)
      result == false ? Sound.play_buzzer : Sound.play_ok
      apply_change
    elsif vk_down?(K::RIGHT, K::D)
      item.on_right(self); Sound.play_cursor; apply_change
    elsif vk_down?(K::LEFT, K::A)
      item.on_left(self);  Sound.play_cursor; apply_change
    end
  end

  # Redraw after an edit, including rows whose availability depends on it.
  # A language switch re-renders the whole menu + header.
  def apply_change
    return if disposed? || @closing
    if language_changed?
      refresh
      refresh_header
    else
      redraw_current_item
      @list.each_with_index do |command, index|
        enabled = command[:ext].selectable?
        next if command[:enabled] == enabled
        command[:enabled] = enabled
        redraw_item(index)
      end
    end
  end

  def language_changed?
    now = ModLoader::ModMenu.language
    changed = now != @lang
    @lang = now
    changed
  end

  def switch_category(dir)
    cats = ModLoader::ModMenu.categories
    return if cats.size <= 1
    remember_position
    @cat_index = (@cat_index + dir) % cats.size
    refresh                # Window_Command: rebuild list + create_contents + redraw
    restore_position
    refresh_header
    Sound.play_cursor
  end
end
