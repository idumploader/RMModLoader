#==============================================================================
# MapExecutorWindow — on-map UI for handing items/weapons/armor to the player.
# Companion to the executor "give" flow.
#
# Hotkey: T opens the give window (freezes player movement while open).
#
# Dependencies: ExecutorModule (700), VKKeys (570), ModLoader,
#               $data_items / $data_weapons / $data_armors.
# Config gate:  ExecutorModule::ENABLED
# Defines: ExecutorGive_Window, ExecutorGiveSwitch_Window, ExecutorGiveList_Window
#==============================================================================

$imported ||= {}
if not $imported["IDL-MapExecutorWindow"]
$imported["IDL-MapExecutorWindow"] = "1.0"

if ExecutorModule::ENABLED

module ExecutorModule
  GIVE_WINDOW_KEY = VKKeys::VK_T
end

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

    update_executor_windows
  end

  def update_executor_windows
    toggle_give_window if not $executor_input_is_disabled and ModLoader.input_trigger?(ExecutorModule::GIVE_WINDOW_KEY)
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

class ExecutorGive_Window < Window_Base
  def initialize
    super(0, 0, window_width, window_height)
    @category_windows = {}
    create_viewport
    create_windows

    update_placement
    self.openness = 0
    open

    @switch_window.activate
  end

  def open
    super
    @switch_window.open
    @current_category_window.open if @current_category_window
  end

  def close
    super
    @switch_window.close
    @current_category_window.close if @current_category_window
  end

  def dispose
    super
    @switch_window.dispose
    @category_windows.each { |k, window| window.dispose }
  end

  def activate
    @switch_window.activate if not @current_category_window or not @current_category_window.active
  end

  def update_placement
    self.x = (Graphics.width - self.width) / 2
    self.y = (Graphics.height - self.height) / 2

    @switch_window.x = self.x + @header_width + 10
    @switch_window.y = self.y

    @category_windows.each do |category, window|
      window.x = self.x
      window.y = self.y + header_height + 14
    end
  end

  def window_width
    return 600
  end

  def window_height
    return 400
  end

  def header_height
    return line_height
  end

  def create_viewport
    @viewport = Viewport.new(0, 0, window_width, window_height)
  end

  def create_windows
    @header_width = self.draw_text(0, 0, window_width, line_height, "Give").width

    @switch_window = ExecutorGiveSwitch_Window.new(window_width - @header_width - 10)
    @switch_window.set_handler(:ok,     method(:on_category_ok))
    @switch_window.set_handler(:cancel, method(:on_category_cancel))
    @switch_window.category_handler = method(:on_category_change)
  end

  def update
    super
    @switch_window.update
    @current_category_window.update
  end

  def on_category_ok
    @current_category_window.activate
    @current_category_window.select_last
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
    @current_category_window.unselect
    @switch_window.activate
  end

  def on_category_change(category)
    return if @current_category == category
    @current_category = category

    category_window = @category_windows[category] if @category_windows.include?(category)
    if not category_window
      category_window= ExecutorGiveList_Window.new(window_width, window_height - line_height)
      category_window.set_handler(:ok,     method(:on_item_ok))
      category_window.set_handler(:cancel, method(:on_item_cancel))

      category_window.category = category
      category_window.x = self.x
      category_window.y = self.y + header_height + 14

      @category_windows[category] = category_window
    end

    @current_category_window.hide if @current_category_window
    @current_category_window = category_window
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
    $game_party.gain_item(item, amount)
  end
end

end # ExecutorModule::ENABLED

end # not $imported["IDL-MapExecutorWindow"]