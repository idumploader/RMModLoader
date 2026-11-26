#==============================================================================
# MapExecutorWindow — on-map UI for handing items/weapons/armor to the player.
# Companion to the executor "give" flow.
#
# Hotkey: T opens the give window (freezes player movement while open).
#
# Dependencies: ExecutorModule (700), ModLoader::Keyboard (7), ModLoader,
#               $data_items / $data_weapons / $data_armors.
# Enabled through Debug settings (checked when opening).
# Defines: ExecutorGive_Window, ExecutorGiveSwitch_Window, ExecutorGiveList_Window
#==============================================================================

$imported ||= {}
if not $imported["IDL-MapExecutorWindow"]
$imported["IDL-MapExecutorWindow"] = "1.0"

if defined?(ExecutorModule)

module ExecutorModule
  GIVE_WINDOW_KEY = ModLoader::Keyboard::T

  GIVE_TEXT = {
    'executor.give.title' => 'Give items',
    'executor.give.tabs_hint' => 'Left/Right: category   Confirm: select',
    'executor.give.tabs_back' => 'Cancel / T: close',
    'executor.give.item_hint' => 'Confirm: give one item',
    'executor.give.item_back' => 'Cancel: categories   T: close'
  }
  GIVE_TEXT.each { |key, text| ModLoader::I18n.define(key, text) }

  def self.give_text(key)
    ModLoader::I18n[key]
  end
end

ModLoader::Hotkeys.register(:executor_give,
  :key => ExecutorModule::GIVE_WINDOW_KEY,
  :enabled => proc { ExecutorModule.enabled? && SceneManager.scene.is_a?(Scene_Map) }
) { |scene| scene.toggle_give_window }

class Game_Player

  alias executor_give_orig_update update

  attr_accessor :executor_give_cannot_move

  def update
    executor_give_orig_update if not @executor_give_cannot_move
  end

end

class Scene_Map
  alias executor_give_orig_update update
  alias executor_give_orig_scene_change_ok? scene_change_ok?

  def update
    # disable player movement if window is open
    if is_executor_give_window_opened?
      $game_player.executor_give_cannot_move = true
      executor_give_orig_update
      $game_player.executor_give_cannot_move = false
    else
      executor_give_orig_update
    end

  end

  def toggle_give_window
    if @executor_give_window == nil or @executor_give_window.disposed?
      @executor_give_window = ExecutorGive_Window.new
      @executor_give_window.activate
    elsif not @executor_give_window.open?
      @executor_give_window.open
      @executor_give_window.activate
    else
      @executor_give_window.close
      @executor_give_window.deactivate
    end
    $wnd = @executor_give_window
  end

  def is_executor_give_window_opened?
    @executor_give_window and not @executor_give_window.disposed? and @executor_give_window.open?
  end
end

class ExecutorGiveList_Window < Window_Selectable
  attr_accessor :category

  def initialize(width, height)
    super(0, 0, width, height)
    refresh
  end

  # -- Menu config
  def col_max
    return 2
  end

  def item_max
    @items ? @items.size : 1
  end

  def item
    @items && index >= 0 ? @items[index] : nil
  end

  def draw_item(index)
    item = @items[index]
    return if not item

    rect = item_rect(index)
    rect.width -= 4
    draw_item_name(item, rect.x, rect.y)
    draw_item_id(rect, item)
  end

  def draw_item_id(rect, item)
    draw_text(rect, sprintf("%03d", item.id), 2)
  end

  def category=(category)
    return if category == @category
    @category = category
    refresh
  end

  def make_items_list
    items = []
    case category
    when :item
      items = $data_items
    when :weapon
      items = $data_weapons
    when :armor
      items = $data_armors
    end
    @items = items.select { |item| item and not item.name.empty? }
  end

  def refresh
    make_items_list
    create_contents
    draw_all_items
  end

  # Keep RGSS's contents coordinates, cursor and scroll arrows intact, but
  # rasterize only rows intersecting the window. Previously the first visit
  # rendered every item in the database before the next game update.
  def create_contents
    @give_drawn_items = {}
    super
  end

  def draw_all_items
    draw_visible_items
  end

  def oy=(value)
    super
    draw_visible_items
  end

  def draw_visible_items
    return unless @items && @give_drawn_items && contents && !contents.disposed?
    visible_height = height - standard_padding * 2
    return if visible_height <= 0 || item_height <= 0
    first_row = [oy / item_height, 0].max
    last_row = (oy + visible_height - 1) / item_height
    first = first_row * col_max
    last = [(last_row + 1) * col_max, item_max].min
    (first...last).each do |index|
      next if @give_drawn_items[index]
      draw_item(index)
      @give_drawn_items[index] = true
    end
  end

  def select_last
    select(0)
  end
end

class ExecutorGiveSwitch_Window < Window_HorzCommand

  attr_accessor :category_handler

  def initialize(width)
    @wnd_width = width
    super(0, 0)
  end

  def window_width
    @wnd_width
  end

  def window_height
    fitting_height(2)
  end

  def contents_height
    height - standard_padding * 2
  end

  def item_rect(index)
    rect = super
    rect.y += line_height
    rect
  end

  def draw_all_items
    change_color(system_color)
    draw_text(0, 0, contents_width, line_height,
      ExecutorModule.give_text('executor.give.title'), 1)
    super
  end

  def col_max
    return 3
  end

  def update
    super
    @category_handler.call(current_symbol) if @category_handler
  end

  def make_command_list
    add_command(Vocab::item,     :item)
    add_command(Vocab::weapon,   :weapon)
    add_command(Vocab::armor,    :armor)
  end

  def item_window=(item_window)
    @item_window = item_window
    update
  end
end

class ExecutorGiveHelp_Window < Window_Base
  def initialize(width)
    super(0, 0, width, fitting_height(2))
  end

  def set(list_active)
    language = ModLoader::I18n.language
    return if @list_active == list_active && @language == language
    @list_active, @language = list_active, language
    contents.clear
    keys = list_active ? ['item_hint', 'item_back'] : ['tabs_hint', 'tabs_back']
    keys.each_with_index do |key, row|
      draw_text(0, row * line_height, contents_width, line_height,
        ExecutorModule.give_text('executor.give.' + key), 1)
    end
  end
end

class ExecutorGive_Window < Window_Base
  def initialize
    super(0, 0, window_width, window_height)
    # Retain Scene_Base's window lifecycle; only the child panels are visible.
    self.opacity = 0
    @category_windows = {}
    create_windows

    update_placement
    self.openness = 0
    @switch_window.openness = 0
    @current_category_window.openness = 0
    @help_window.openness = 0
    open

    @switch_window.activate
  end

  def contents_width; 1; end
  def contents_height; 1; end

  def open
    super
    @switch_window.open
    @current_category_window.open if @current_category_window
    @help_window.open
  end

  def close
    super
    @switch_window.close
    @current_category_window.close if @current_category_window
    @help_window.close
    @switch_window.deactivate
    @current_category_window.deactivate if @current_category_window
  end

  def dispose
    super
    @switch_window.dispose
    @category_windows.each { |k, window| window.dispose }
    @help_window.dispose
    @viewport.dispose if @viewport && !@viewport.disposed?
  end

  def activate
    @switch_window.activate if not @current_category_window or not @current_category_window.active
  end

  def update_placement
    self.x = (Graphics.width - self.width) / 2
    self.y = (Graphics.height - self.height) / 2

    @switch_window.x = self.x
    @switch_window.y = self.y
    @help_window.x = self.x
    @help_window.y = self.y + height - @help_window.height

    @category_windows.each do |category, window|
      window.x = self.x
      window.y = self.y + @switch_window.height + 4
    end
  end

  def window_width
    return [720, Graphics.width - 32].min
  end

  def window_height
    return [600, Graphics.height - 32].min
  end

  def header_height
    @switch_window.height
  end

  def create_windows
    @switch_window = ExecutorGiveSwitch_Window.new(width)
    @switch_window.set_handler(:ok,     method(:on_category_ok))
    @switch_window.set_handler(:cancel, method(:on_category_cancel))
    @switch_window.category_handler = method(:on_category_change)
    @help_window = ExecutorGiveHelp_Window.new(width)
    @ui_language = ModLoader::I18n.language
    on_category_change(@switch_window.current_symbol)
  end

  def update
    super
    if @ui_language != ModLoader::I18n.language
      @ui_language = ModLoader::I18n.language
      @switch_window.refresh
    end
    @switch_window.update
    @current_category_window.update if @current_category_window
    @help_window.set(@current_category_window && @current_category_window.active)
    @help_window.update
  end

  def on_category_ok
    @switch_window.deactivate
    @current_category_window.activate
    @current_category_window.select_last if @current_category_window.index < 0
  end

  def on_category_cancel
    deactivate
    close
  end

  def on_item_ok
    give_player_item(@current_category_window.item)
    @current_category_window.activate
  end

  def on_item_cancel
    @current_category_window.deactivate
    @switch_window.activate
  end

  def on_category_change(category)
    return if @current_category == category
    @current_category = category

    category_window = @category_windows[category] if @category_windows.include?(category)
    if not category_window
      list_height = height - @switch_window.height - @help_window.height - 8
      category_window = ExecutorGiveList_Window.new(width, list_height)
      category_window.set_handler(:ok,     method(:on_item_ok))
      category_window.set_handler(:cancel, method(:on_item_cancel))

      category_window.category = category
      category_window.x = self.x
      category_window.y = self.y + @switch_window.height + 4

      @category_windows[category] = category_window
    end

    if @current_category_window
      @current_category_window.deactivate
      @current_category_window.hide
    end
    @current_category_window = category_window
    @current_category_window.openness = @switch_window.openness
    @current_category_window.open if @opening || open?
    @current_category_window.show
  end


  def give_player_item(item)
    amount = 1
    category = 0
    category_name = ""
    if item.is_a?(RPG::Item)
      category = 0
      category_name = CUSTOM_GET_WINDOW::ITEM_TEXT_ADD
    elsif item.is_a?(RPG::Weapon)
      category = 1
      category_name = CUSTOM_GET_WINDOW::WEAPON_TEXT_ADD
    elsif item.is_a?(RPG::Armor)
      category = 2
      category_name = CUSTOM_GET_WINDOW::ARMOR_TEXT_ADD
    else
      return
    end

    $game_temp.streffect.push(Window_Getinfo.new(item.id, category, category_name, amount))
    # The game's popup can grant the item itself (CUSTOM_GET_WINDOW::GET).
    # Only grant here when the popup is configured as a notification.
    popup_grants_item = Window_Getinfo.const_defined?(:GET) && Window_Getinfo::GET
    $game_party.gain_item(item, amount) unless popup_grants_item
  end
end

end # defined?(ExecutorModule)

end # not $imported["IDL-MapExecutorWindow"]
