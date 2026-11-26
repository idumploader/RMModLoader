# Extends 455 - BSResolutionFix for the game's menu, Oxib status and save UI.
$imported ||= {}
unless $imported['BS-MenuResolutionFix']
$imported['BS-MenuResolutionFix'] = true
if ModLoader.hrfix_enabled && defined?(BSResolutionFix)
module BSResolutionFix
  # Convert authored coordinates before drawing, rather than stretching a
  # finished low-resolution window. Used only while fixed-layout UI refreshes.
  class CanvasFont
    attr_reader :native_font
    def initialize(font, scale); @font, @native_font, @scale = font, font, scale; end
    def clone; CanvasFont.new(@font.clone, @scale); end
    def size; (@font.size / @scale).round; end
    def size=(value); @font.size = [(value * @scale).round, 96].min; end
    def method_missing(name, *args); @font.send(name, *args); end
  end
  class Canvas
    def initialize(bitmap, scale)
      @bitmap, @scale = bitmap, scale
      @font = CanvasFont.new(bitmap.font, scale)
    end
    def font; @font; end
    def font=(value)
      @bitmap.font = value.is_a?(CanvasFont) ? value.native_font : value
      @font = CanvasFont.new(@bitmap.font, @scale)
    end
    def width; (@bitmap.width / @scale).round; end
    def height; (@bitmap.height / @scale).round; end
    def rect; Rect.new(0, 0, width, height); end
    def text_size(text)
      r = @bitmap.text_size(text)
      Rect.new(0, 0, (r.width / @scale).round, (r.height / @scale).round)
    end
    def scaled_rect(rect)
      x = (rect.x * @scale).round; y = (rect.y * @scale).round
      Rect.new(x, y, ((rect.x + rect.width) * @scale).round - x,
        ((rect.y + rect.height) * @scale).round - y)
    end
    def coordinates(args)
      if args[0].is_a?(Rect)
        [scaled_rect(args[0])] + args[1..-1]
      else
        rect = scaled_rect(Rect.new(*args[0, 4]))
        [rect.x, rect.y, rect.width, rect.height] + args[4..-1]
      end
    end
    [:draw_text, :draw_text_f, :fill_rect, :clear_rect, :gradient_fill_rect].each do |name|
      define_method(name) { |*args| @bitmap.send(name, *coordinates(args)) }
    end
    def blt(x, y, bitmap, source, opacity = 255)
      @bitmap.stretch_blt(scaled_rect(Rect.new(x, y, source.width, source.height)), bitmap, source, opacity)
    end
    def stretch_blt(target, bitmap, source, opacity = 255)
      @bitmap.stretch_blt(scaled_rect(target), bitmap, source, opacity)
    end
    def method_missing(name, *args); @bitmap.send(name, *args); end
  end
  module CanvasWindow
    def contents
      bitmap = super
      return bitmap unless @bsresolution_drawing_canvas && bitmap
      Canvas.new(bitmap, @bsresolution_canvas_scale)
    end
    def standard_padding
      @bsresolution_canvas_scale ? (super * @bsresolution_canvas_scale).round : super
    end
    def bsresolution_enable_canvas
      @bsresolution_canvas_scale = BSResolutionFix.scale
      self.width = (width * @bsresolution_canvas_scale).round
      self.height = (height * @bsresolution_canvas_scale).round
      self.padding = standard_padding
      create_contents
      refresh
    end
    def bsresolution_canvas_refresh
      @bsresolution_drawing_canvas = true
      reset_font_settings
      yield
    ensure
      @bsresolution_drawing_canvas = false
    end
    def draw_actor_face(actor, x, y, enabled = true)
      bitmap = Cache.face(actor.face_name)
      source = BSFaceSheet.rect(bitmap, actor.face_index)
      contents.stretch_blt(Rect.new(x, y, 96, 96), bitmap, source, enabled ? 255 : translucent_alpha)
    end
  end
  module NativeActorDrawing
    def bsresolution_face(actor, x, y, size, enabled = true)
      bitmap = Cache.face(actor.face_name)
      source = BSFaceSheet.rect(bitmap, actor.face_index)
      contents.stretch_blt(Rect.new(x, y, size, size), bitmap, source, enabled ? 255 : translucent_alpha)
    end
    def bsresolution_resource(actor, x, y, width, kind)
      hp = kind == :hp
      draw_gauge(x, y, width, hp ? actor.hp_rate : actor.mp_rate,
        hp ? hp_gauge_color1 : mp_gauge_color1, hp ? hp_gauge_color2 : mp_gauge_color2)
      label = BSResolutionFix.pixels(32)
      change_color(system_color)
      draw_text(x, y, label, line_height, hp ? Vocab::hp_a : Vocab::mp_a)
      change_color(hp ? hp_color(actor) : mp_color(actor))
      value = hp ? "#{actor.hp}/#{actor.mhp}" : "#{actor.mp}/#{actor.mmp}"
      draw_text(x + label, y, [width - label, 0].max, line_height, value, 2)
    end
  end
  def self.category_scale; 1.0 + (scale - 1.0) * 0.65; end
  def self.command_width(base, commands)
    bitmap = Bitmap.new(1, 1)
    begin
      bitmap.font.size = pixels(Font.default_size)
      text_width = (commands || []).map { |entry| bitmap.text_size(entry[:name]).width }.max || 0
      [[pixels(base), text_width + pixels(36)].max, Graphics.width].min
    ensure
      bitmap.dispose
    end
  end
  def self.menu_column_width
    scene = SceneManager.scene
    window = scene && scene.instance_variable_get(:@command_window)
    window.is_a?(Window_MenuCommand) ? window.width : pixels(160)
  end
end

[Window_GameEnd, Window_TitleCommand, Window_MenuCommand, Window_Gold, Window_MenuStatus, Window_EquipCommand,
 Window_EquipSlot, Window_SaveFile].each { |klass| klass.send(:include, BSResolutionFix::WindowMetrics) }
Window_MenuStatus.send(:include, BSResolutionFix::NativeActorDrawing)

class Window_GameEnd
  alias bsresolution_end_width window_width
  def window_width; BSResolutionFix.pixels(bsresolution_end_width); end
end

if defined?(Window_State)
class Window_State
  include BSResolutionFix::WindowMetrics
  def item_height; line_height + BSResolutionFix.pixels(2); end
  def item_width; item_height; end
  def fitting_window
    available = [Graphics.height - @help_window.height, 1].max
    self.height = [item_height * row_max + standard_padding * 2, available].min
    self.width = [BSResolutionFix.pixels(144) + col_max * item_width + standard_padding * 2, Graphics.width].min
    self.x = (Graphics.width - width) / 2
    self.y = [(@help_window.height + Graphics.height - height) / 2, @help_window.height].max
  end
  def refresh
    fitting_window
    make_data
    create_contents
    name_width = BSResolutionFix.pixels(128)
    icons_x = BSResolutionFix.pixels(144)
    all_battle_members.each_with_index do |subject, index|
      y = index * item_height + BSResolutionFix.pixels(1)
      draw_actor_name(subject, 0, y, name_width)
      draw_text(name_width, y, BSResolutionFix.pixels(20), line_height, ':')
      draw_icons(subject, icons_x, y, contents.width - icons_x)
      draw_turns(subject, icons_x, y, contents.width - icons_x)
    end
  end
  def draw_turns(subject, x, y, width = 96)
    last_font = contents.font.clone
    begin
      contents.font.size = BSResolutionFix.pixels(19)
      contents.font.bold = true
      contents.font.color = crisis_color
      turns = (subject.state_turns + subject.buff_turns)[0, width / item_width]
      turns.each_with_index do |turns_left, index|
        next if turns_left <= 0
        draw_text(x + item_width * index, y, item_width, line_height, turns_left.to_s, 2)
      end
    ensure
      contents.font = last_font
    end
  end
  def item_rect(index)
    Rect.new(index % col_max * item_width + BSResolutionFix.pixels(143),
      index / col_max * item_height, item_width, item_height)
  end
end
end

class Window_TitleCommand
  alias bsresolution_title_width window_width
  def window_width; BSResolutionFix.pixels(bsresolution_title_width); end
end
class Window_MenuCommand
  alias bsresolution_menu_width window_width
  def window_width; BSResolutionFix.command_width(bsresolution_menu_width, @list); end
end
class Window_Gold
  alias bsresolution_gold_width window_width
  def window_width; BSResolutionFix.menu_column_width; end
  def draw_currency_value(value, unit, x, y, width)
    unit_width = text_size(unit).width
    change_color(normal_color)
    draw_text(x, y, width - unit_width - BSResolutionFix.pixels(4), line_height, value, 2)
    change_color(system_color)
    draw_text(x + width - unit_width, y, unit_width, line_height, unit, 2)
  end
end
class Window_MenuStatus
  def window_width; Graphics.width - BSResolutionFix.menu_column_width; end
  def draw_item(index)
    actor = $game_party.members[index]
    rect = item_rect(index)
    enabled = $game_party.battle_members.include?(actor)
    draw_item_background(index)
    gap = BSResolutionFix.pixels(8)
    face = [BSResolutionFix.pixels(96), rect.height - gap * 2].min
    bsresolution_face(actor, rect.x + gap, rect.y + (rect.height - face) / 2, face, enabled)
    x = rect.x + face + gap * 2
    y = rect.y + (rect.height - line_height * 3) / 2
    name_width = [BSResolutionFix.pixels(180), (rect.width - face - gap * 3) / 2].min
    draw_actor_name(actor, x, y, name_width)
    change_color(system_color, enabled)
    draw_text(x, y + line_height, name_width, line_height, "#{Vocab::level_a} #{actor.level}")
    draw_actor_icons(actor, x, y + line_height * 2, name_width)
    gx = x + name_width + gap
    gw = [rect.x + rect.width - gx - gap, 1].max
    draw_actor_class(actor, gx, y, gw)
    bsresolution_resource(actor, gx, y + line_height, gw, :hp)
    bsresolution_resource(actor, gx, y + line_height * 2, gw, :mp)
  end
end

# The game's menu location and three variable windows are separate classes.
if defined?(Window_Mapname)
class Window_Mapname
  include BSResolutionFix::WindowMetrics
  alias bsresolution_location_width window_width
  alias bsresolution_location_height window_height
  def window_width; BSResolutionFix.pixels(bsresolution_location_width); end
  def window_height; BSResolutionFix.pixels(bsresolution_location_height); end
  def refresh
    contents.clear
    reset_font_settings
    change_color(system_color)
    draw_text(0, 0, contents.width, line_height, "\u041c\u0435\u0441\u0442\u043e\u043f\u043e\u043b\u043e\u0436\u0435\u043d\u0438\u0435")
    change_color(normal_color)
    draw_text(0, line_height, contents.width, line_height, $game_map.display_name)
  end
end
end
if defined?(Prico)
[Window_Var1, Window_Var2, Window_Var3].each_with_index do |klass, index|
  klass.send(:include, BSResolutionFix::WindowMetrics)
  klass.class_eval do
    alias bsresolution_variable_initialize initialize
    define_method(:initialize) do
      @bsresolution_variable_index = index + 1
      bsresolution_variable_initialize
      self.width = BSResolutionFix.menu_column_width
      self.height = fitting_height(2) - BSResolutionFix.pixels(8)
      self.padding = standard_padding
      create_contents
      refresh
    end
    define_method(:refresh) do
      contents.clear
      reset_font_settings
      n = @bsresolution_variable_index
      prefix = Prico.const_get("Var_Prefix#{n}")
      suffix = Prico.const_get("Var_Suffix#{n}").to_s
      value = $game_variables[Prico.const_get("Var_Num#{n}")]
      change_color(system_color)
      draw_text(0, -BSResolutionFix.pixels(2), contents.width, line_height, prefix)
      change_color(normal_color)
      text = suffix.empty? ? value.to_s : "#{value} #{suffix}"
      draw_text(0, line_height - BSResolutionFix.pixels(4), contents.width, line_height, text, 2)
    end
  end
end
end
class Scene_Menu
  alias bsresolution_auxiliary_start start
  def start
    bsresolution_auxiliary_start
    if @map_window
      @map_window.x = Graphics.width - @map_window.width
      @map_window.y = Graphics.height - @map_window.height
    end
    bottom = @gold_window.y
    [@Var_window1, @Var_window2, @Var_window3].compact.each do |window|
      bottom -= window.height + BSResolutionFix.pixels(4)
      window.x = @gold_window.x
      window.y = bottom
    end
  end
end

module BSResolutionFix
  module CategoryMetrics
    def line_height; (super * BSResolutionFix.category_scale).round; end
    def standard_padding; (super * BSResolutionFix.category_scale).round; end
    def reset_font_settings(*args)
      super(*args)
      contents.font.size = (contents.font.size * BSResolutionFix.category_scale).round
    end
    def create_contents
      super
      reset_font_settings
    end
  end
end
class Window_ItemCategory
  include BSResolutionFix::CategoryMetrics
end

class Window_EquipStatus
  include BSResolutionFix::CanvasWindow
  alias bsresolution_equip_initialize initialize
  def initialize(x, y)
    bsresolution_equip_initialize(x, y)
    bsresolution_enable_canvas
  end
  alias bsresolution_equip_refresh refresh
  def refresh
    return bsresolution_equip_refresh unless @bsresolution_canvas_scale
    bsresolution_canvas_refresh { bsresolution_equip_refresh }
  end
end
class Window_EquipSlot
  # The equipment extension allocates its bitmap directly, bypassing super.
  alias bsresolution_slot_create_contents create_contents
  def create_contents
    bsresolution_slot_create_contents
    reset_font_settings
  end
  def draw_item(index)
    return unless @actor
    rect = item_rect_for_text(index)
    label = BSResolutionFix.pixels(92)
    change_color(system_color, enable?(index))
    draw_text(rect.x, rect.y, label, line_height, slot_name(index))
    draw_item_name(@actor.equips[index], rect.x + label, rect.y, enable?(index), rect.width - label)
  end
end

if defined?(Oxib_status)
class Window_Status
  include BSResolutionFix::CanvasWindow
  alias bsresolution_status_initialize initialize
  def initialize(actor)
    bsresolution_status_initialize(actor)
    bsresolution_enable_canvas
    self.x = (Graphics.width - width) / 2
    self.y = (Graphics.height - height) / 2
  end
  alias bsresolution_status_refresh refresh
  def refresh
    return bsresolution_status_refresh unless @bsresolution_canvas_scale
    bsresolution_canvas_refresh { bsresolution_status_refresh }
  end
  alias bsresolution_status_window_width window_width
  alias bsresolution_status_window_height window_height
  def window_width
    return (width / @bsresolution_canvas_scale).round - 32 if @bsresolution_drawing_canvas
    bsresolution_status_window_width
  end
  def window_height
    return (height / @bsresolution_canvas_scale).round - 32 if @bsresolution_drawing_canvas
    bsresolution_status_window_height
  end
end
end

# BEGIN MAP NOTIFICATIONS
module BSResolutionFix
  # Keep the previous constant for scripts using this metrics mixin.
  NotificationMetrics = CategoryMetrics
end
Window_MapName.send(:include, BSResolutionFix::NotificationMetrics)
if defined?(Window_Getinfo)
class Window_Getinfo
  include BSResolutionFix::CanvasWindow
  alias bsresolution_getinfo_initialize initialize
  alias bsresolution_getinfo_refresh refresh
  def initialize(*args)
    @bsresolution_getinfo_initializing = true
    bsresolution_getinfo_initialize(*args)
    @bsresolution_canvas_scale = BSResolutionFix.category_scale
    self.x = (-16 * @bsresolution_canvas_scale).round
    self.width = (672 * @bsresolution_canvas_scale).round
    self.height = (70 * @bsresolution_canvas_scale).round
    self.padding = standard_padding
    create_contents
    if Y_TYPE == 0
      self.y = ((-14 + @i * 40) * @bsresolution_canvas_scale).round
    else
      self.y = Graphics.height - ((58 + @i * 40) * @bsresolution_canvas_scale).round
    end
    @bsresolution_getinfo_initializing = false
    # The original refresh grants the item. Execute it exactly once.
    refresh(*@bsresolution_getinfo_pending)
    @bsresolution_getinfo_pending = nil
  end
  def refresh(*args)
    if @bsresolution_getinfo_initializing
      @bsresolution_getinfo_pending = args
      return
    end
    bsresolution_canvas_refresh do
      bsresolution_getinfo_refresh(*args)
      bsresolution_redraw_item_notice(*args) if (0..2).include?(args[1])
    end
  end
  def bsresolution_fit_notice_text(text, width)
    return text if contents.text_size(text).width <= width
    shortened = text.dup
    shortened = shortened[0, shortened.length - 1] while !shortened.empty? && contents.text_size(shortened + '...').width > width
    shortened.empty? ? '' : shortened + '...'
  end
  def bsresolution_redraw_item_notice(id, type, text, value)
    data = [$data_items, $data_weapons, $data_armors][type][id]
    reset_font_settings
    quantity = "\u0445 #{value}"
    quantity_width = contents.text_size(quantity).width + 8
    name_width = [contents.text_size(data.name).width + 28, (contents.width * 0.48).floor].min
    quantity_x = 4 + name_width + 8
    description_x = quantity_x + quantity_width + 12
    @bsresolution_getinfo_columns = [4 + name_width, quantity_x, quantity_x + quantity_width, description_x]
    contents.clear
    contents.fill_rect(0, 14, contents.width, 24, B_COLOR)
    display = data.dup
    display.name = bsresolution_fit_notice_text(data.name, [name_width - 28, 0].max)
    draw_icon(data.icon_index, 4, 14)
    color = normal_color
    if defined?(ItemLevelDrawer) && data.note =~ /<\u54c1\u8d28 (\d+)>/i
      palette = ItemLevelDrawer::ColorSet[[$1.to_i - 1, 0].max]
      color = palette.is_a?(Color) ? palette : Color.new(*palette) if palette
    end
    change_color(color)
    # The game's quality drawer uses draw_text_ex without a width limit.
    contents.draw_text(32, 14, [name_width - 28, 0].max, line_height, display.name)
    change_color(normal_color)
    contents.draw_text(quantity_x, 14, quantity_width, line_height, quantity)
    description_width = [contents.width - description_x - 4, 0].max
    contents.draw_text(description_x, 14, description_width, line_height,
      bsresolution_fit_notice_text(description(data), description_width))
    contents.font.size = 14
    caption_width = [contents.text_size(text).width + 4, contents.width].min
    contents.fill_rect(0, 0, caption_width, 14, B_COLOR)
    contents.draw_text_f(4, 0, contents.width - 4, 14, text)
  end
end
end
# END MAP NOTIFICATIONS

class Window_SaveFile
  # One compact row: slot and larger walking icons at left,
  # playtime at right; all text vertically centred in the available height.
  def refresh
    contents.clear
    reset_font_settings
    change_color(normal_color)
    auto = $game_system && $game_system.respond_to?(:in_autosave_mode) && $game_system.in_autosave_mode
    prefix = auto && defined?(AUTOSAVE_CONFIG) ? AUTOSAVE_CONFIG::SHORT_NAME : Vocab::File
    name = "#{prefix} #{@file_index + 1}"
    y = (contents.height - line_height) / 2
    @name_width = text_size(name).width
    draw_text(BSResolutionFix.pixels(4), y, contents.width / 3, line_height, name)
    @bsresolution_cursor_y = y
    header = DataManager.load_header(@file_index)
    return unless header
    characters = header[:characters] || []
    size_scale = 1.0 + (BSResolutionFix.scale - 1.0) * 0.8
    spacing = (48 * size_scale).round
    # Position the first sprite by its left edge after the measured slot text.
    first = BSResolutionFix.pixels(4) + @name_width + BSResolutionFix.pixels(16)
    characters.each_with_index do |data, i|
      bitmap = Cache.character(data[0])
      single = data[0] =~ /\A[!]?\$/
      cw = bitmap.width / (single ? 3 : 12)
      ch = bitmap.height / (single ? 4 : 8)
      n = data[1]
      source = single ? Rect.new(cw, 0, cw, ch) : Rect.new((n % 4 * 3 + 1) * cw, n / 4 * 4 * ch, cw, ch)
      fit = [size_scale, contents.height.to_f / ch].min
      w = (cw * fit).round; h = (ch * fit).round
      contents.stretch_blt(Rect.new(first + i * spacing, (contents.height - h) / 2, w, h), bitmap, source)
    end
    draw_text(contents.width * 2 / 3, y, contents.width / 3 - BSResolutionFix.pixels(4), line_height, header[:playtime_s].to_s, 2)
  end
  def update_cursor
    if @selected
      cursor_rect.set(0, @bsresolution_cursor_y || 0, @name_width + BSResolutionFix.pixels(8), line_height)
    else
      cursor_rect.empty
    end
  end
end
class Scene_File
  def savefile_height
    [BSResolutionFix.pixels(64), @savefile_viewport.rect.height].min
  end
  def visible_max
    [@savefile_viewport.rect.height / savefile_height, 1].max
  end
end
end
end
