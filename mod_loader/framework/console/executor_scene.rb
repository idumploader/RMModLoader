#==============================================================================
# ExecutorScene — in-game developer console: run arbitrary Ruby during play,
# with command history and error highlighting.
#
# Hotkey: F9 toggles the console (enabled in Debug settings).
#
# ExecutorEnvironment here is just the eval engine (execute = raw eval). The
# default console commands (give/tp/bind/...) live in ExecutorDefaultCommands
# (705); ModResetter provides reset.
#
# Dependencies: ModLoader::Keyboard (7), InputCapture/TextInput/Clipboard (8).
# Version gate: ModLoader.version != "2.4"
# Defines: ExecutorModule, ExecutorEnvironment, Executor_Window, ExecutedCommand
#==============================================================================

$imported ||= {}
if not $imported["IDL-ExecutorScene"]
$imported["IDL-ExecutorScene"] = "1.0"

if ModLoader.version != "2.4"

module ExecutorModule
  COMMANDS_HISTORY = []
  def self.enabled?
    ModLoader::ModMenu['debug.console'] == true
  end
end

ModLoader::ModMenu.category('Debug', :id => :modloader_console) do |menu|
  menu.header('Console')
  menu.toggle('Developer console', :id => :console_enabled,
    :key => 'debug.console', :default => false,
    :description => 'Enable the Ruby console (F9) and item giver (T). Applies immediately and is saved.')
end

ModLoader::Hotkeys.register(:console,
  :key => ModLoader::Keyboard::F9, :capture => :console,
  :enabled => proc { ExecutorModule.enabled? }
) { |scene| scene.toggle_executor_window }

class Scene_Base
  def toggle_executor_window
    # Window_Selectable#initialize calls deactivate. Acquire only after creation,
    # otherwise that call releases the capture and arms the key-release guard.
    return if ModLoader::InputCapture.blocked? && ModLoader::InputCapture.owner != :console
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
    @executor_window.activate
  end

end

class Executor_Window < Window_Selectable
  K = ModLoader::Keyboard
  attr_reader :input

  def initialize
    super(0, 0, window_width, window_height)
    update_placement
    self.openness = 0
    open

    @input = ModLoader::TextInput::Line.new
    @current_text_index = 0

    update_exec_symbols
  end

  def dispose
    super
  ensure
    ModLoader::InputCapture.release(:console)
  end

  def activate
    return self unless ModLoader::InputCapture.acquire(:console)
    super
  end

  def deactivate
    super
    ModLoader::InputCapture.release(:console)
  end

  def update
    super
    return if not active
    begin
      check_new_symbols
    rescue StandardError, SyntaxError => error
      p error
    end

  end

  def window_width
    return Graphics.width
  end

  def window_height
    return Graphics.height / 4
  end

  def line_height
    [super, Font.default_size + 8].max
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
      ret = ExecutorEnvironment.execute(@input.text)
      if ret != nil and ret.respond_to?(:to_s)
        ret = ret.to_s[0..max_characters_count]
      else
        ret = "nil"
      end
      new_command = ExecutedCommand.new('Command', @input.text, ret)
    rescue StandardError, SyntaxError => error
      new_command = ExecutedCommand.new('Error', @input.text, error.to_s)
    end

    ExecutorModule::COMMANDS_HISTORY.push(new_command)

    while ExecutorModule::COMMANDS_HISTORY.count > max_command_count
      ExecutorModule::COMMANDS_HISTORY.shift
    end

    @input.replace('')
    @current_text_index = 0
  end

  def check_new_symbols
    revision = @input.revision
    submitted = false
    unless ModLoader::TextInput.update(@input)
      if ModLoader.input_trigger?(K::RETURN)
        execute_symbols
        submitted = true
      elsif ModLoader.input_trigger?(K::UP) && @current_text_index < ExecutorModule::COMMANDS_HISTORY.count
        @current_text_index += 1
        @input.replace(ExecutorModule::COMMANDS_HISTORY[-@current_text_index].command)
      elsif ModLoader.input_trigger?(K::DOWN) && @current_text_index > 0
        @current_text_index -= 1
        text = @current_text_index == 0 ? '' : ExecutorModule::COMMANDS_HISTORY[-@current_text_index].command
        @input.replace(text)
      end
    end
    update_exec_symbols if submitted || revision != @input.revision
  end

  def max_command_count
    return 30
  end

  def update_exec_symbols
    contents.clear
    rect = Rect.new(0, 0, contents.width, line_height)
    draw_history(rect)
    ModLoader::TextInput.draw(self, rect, @input, :prompt => ">>> ")
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
end

end # ModLoader.version != "2.4"

end # not $imported["IDL-ExecutorScene"]
