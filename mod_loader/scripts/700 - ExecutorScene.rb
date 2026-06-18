#==============================================================================
# ExecutorScene — in-game developer console: run arbitrary Ruby during play,
# with command history and error highlighting.
#
# Hotkey: F9 toggles the console (only while ExecutorModule::ENABLED).
#
# Console commands (ExecutorEnvironment):
#   give(id, amount)     maptp(id)            tp(x, y)
#   run_event(id)        setvar(id, value)    setswitch(id, value)
#   toggleswitch(id)     reset                — plus raw eval()
#
# Dependencies: VKKeys (570), ModLoader input API.
# Version gate: ModLoader.version != "2.4"
# Defines: ExecutorModule, ExecutorEnvironment, Executor_Window, ExecutedCommand
#==============================================================================

$imported ||= {}
if not $imported["IDL-ExecutorScene"]
$imported["IDL-ExecutorScene"] = "1.0"

if ModLoader.version != "2.4"

module ExecutorModule
  COMMANDS_HISTORY = []
  ENABLED = false
end

$executor_input_is_disabled = false

class Scene_Base

  alias executor_orig_update update
  def update
    toggle_executor_window if ExecutorModule::ENABLED and ModLoader.input_trigger?(VKKeys::VK_F9)
    executor_orig_update
  end

  def toggle_executor_window
    if @executor_window == nil or @executor_window.disposed?
      @executor_window = Executor_Window.new
      @executor_window.z = 1000
      @executor_window.activate
    elsif not @executor_window.open?
      @executor_window.open
      @executor_window.activate
    else
      @executor_window.close
      @executor_window.deactivate
    end
  end

end

module Input
  class << self
    alias executor_orig_trigger? trigger?
    alias executor_orig_repeat? repeat?
    alias executor_orig_dir4 dir4
    alias executor_orig_dir8 dir8
  end

  def self.trigger?(key)
    Input.executor_orig_trigger?(key) if not $executor_input_is_disabled
  end

  def self.repeat?(key)
    Input.executor_orig_repeat?(key) if not $executor_input_is_disabled
  end

  def self.dir4
    return Input.executor_orig_dir4 if not $executor_input_is_disabled
    return -1
  end

  def self.dir8
    return Input.executor_orig_dir8 if not $executor_input_is_disabled
    return -1
  end
end

class ExecutedCommand
  def initialize(type, command, value)
    @type = type
    @command = command
    @value = value
  end

  def is_error?
    return @type == "Error"
  end

  def value
    return @value
  end

  def command
    return @command
  end
end

class Executor_Scene < Scene_MenuBase

  def start
    super
    create_executor_window
  end

  def update
    super
  end

  def create_executor_window
    @executor_window = Executor_Window.new
  end

end

class Executor_Window < Window_Selectable
  def initialize
    super(0, 0, window_width, window_height)
    update_placement
    self.openness = 0
    open

    @current_text = ''
    @current_text_index = 0

    update_exec_symbols
  end

  def dispose
    super
    $executor_input_is_disabled = false
  end

  def activate
    super
    $executor_input_is_disabled = true
  end

  def deactivate
    super
    $executor_input_is_disabled = false
  end

  def update
    super
    return if not active
    begin
      check_new_symbols
    rescue Exception => error
      p error
    end

  end

  def window_width
    return Graphics.width
  end

  def window_height
    return Graphics.height / 4
  end

  def max_line_count
    return contents.rect.height / line_height
  end

  def max_characters_count
    return window_height / 1.5
  end

  def update_placement
    self.x = 0
    self.y = 0
  end

  def execute_symbols
    begin
      ret = ExecutorEnvironment.execute(@current_text)
      if ret != nil and ret.respond_to?(:to_s)
        ret = ret.to_s[0..max_characters_count]
      else
        ret = "nil"
      end
      new_command = ExecutedCommand.new('Command', @current_text, ret)
    rescue Exception => error
      new_command = ExecutedCommand.new('Error', @current_text, error.to_s)
    end

    ExecutorModule::COMMANDS_HISTORY.push(new_command)

    while ExecutorModule::COMMANDS_HISTORY.count > max_command_count
      ExecutorModule::COMMANDS_HISTORY.shift
    end

    @current_text = ''
    @current_text_index = 0
  end

  def check_new_symbols
    for i in 0..0xFE do
      if ModLoader.input_trigger?(i)
        if i == VKKeys::VK_BACK
          # process separately
        elsif i == VKKeys::VK_RETURN
          execute_symbols
        elsif i == VKKeys::VK_UP and ExecutorModule::COMMANDS_HISTORY.count > 0 and @current_text_index < ExecutorModule::COMMANDS_HISTORY.count
          # next command
          @current_text = ExecutorModule::COMMANDS_HISTORY[-(@current_text_index + 1)].command
          @current_text_index += 1
        elsif i == VKKeys::VK_DOWN and @current_text_index > 1
          # previous command
          @current_text = ExecutorModule::COMMANDS_HISTORY[-(@current_text_index - 1)].command
          @current_text_index -= 1
        elsif i == VKKeys::VK_DOWN and @current_text_index == 1
          # empty command
          @current_text = ""
          @current_text_index -= 1
        else
          # just accumulate character
          character = ModLoader.map_char(i)
          @current_text += character.chr if character
        end
        update_exec_symbols
      end
    end

    if ModLoader.input_repeat?(VKKeys::VK_BACK)
      @current_text = @current_text[0...-1]
      update_exec_symbols
    end
  end

  def max_command_count
    return 30
  end

  def update_exec_symbols
    contents.fill_rect(0, 0, window_width, window_height, Color.new(0, 0, 0, 0))

    rect = Rect.new
    rect.x = 0
    rect.y = 0
    rect.width = window_width
    rect.height = line_height

    draw_history(rect)
    draw_text(rect, '>>> ' + @current_text, 0)
  end

  def draw_history(rect)
    return rect if ExecutorModule::COMMANDS_HISTORY.count == 0
    visible_commands = ExecutorModule::COMMANDS_HISTORY.last(max_line_count / 2)
    return rect if not visible_commands

    # if has partial command, draw only value
    if visible_commands.count * 2 > max_line_count - 1
      draw_command_value(rect, visible_commands[0])
      visible_commands.shift
      rect.y += line_height
    end

    for command in visible_commands do
      draw_text(rect, '>>> ' + command.command, 0)
      rect.y += line_height
      draw_command_value(rect, command)
      rect.y += line_height
    end

    rect
  end

  def command_error_color
    return Color.new(255, 0, 0)
  end

  def draw_command_value(rect, command)
    if command.is_error?
      b_color = contents.font.color.dup
      contents.font.color = command_error_color
      draw_text(rect, command.value, 0)
      contents.font.color = b_color
    else
      draw_text(rect, command.value, 0)
    end
  end
end

module ExecutorEnvironment
  def self.execute(command)
    return eval(command)
  end

  def self.give(id, amount)
    return "Item not found" if $data_items[id] == nil
    $game_party.gain_item($data_items[id], amount)
  end

  def self.maptp(id)
    $game_map.setup(id)
    $game_map.autoplay
  end

  def self.tp(x, y)
    $game_player.moveto(x, y)
  end

  def self.run_event(id)
    child = Game_Interpreter.new(3)
    child.setup($data_common_events[id].list, false)
    child.run
  end

  def self.setvar(id, value)
    $game_variables[id] = value
  end

  def self.setswitch(id, value)
    $game_switches[id] = value
  end

  def self.toggleswitch(id)
    $game_switches[id] ^= true
  end
end

end # ModLoader.version != "2.4"

end # not $imported["IDL-ExecutorScene"]