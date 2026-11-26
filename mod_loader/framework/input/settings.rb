# Input settings use NVRAM; HTTP can be toggled without restarting the game.
$imported ||= {}
unless $imported["IDL-ModLoaderInputSettings"]
$imported["IDL-ModLoaderInputSettings"] = "1.0"

module ModLoader
  module InputSettings
    DEFAULT_HTTP_PORT = 27420
    class << self
      def settings; ModLoader.nvram.section(:input); end

      def http_enabled?; settings[:http_enabled] == true; end

      def http_available?
        defined?(ModLoader::Http) && ModLoader.respond_to?(:http_listen) &&
          ModLoader.respond_to?(:http_stop)
      end

      def http_running?; http_available? && ModLoader::Http.running?; end

      def save_http_enabled(value)
        return false unless http_available?
        was_running = ModLoader::Http.running?
        previous_port = ModLoader::Http.port
        return false unless ModLoader::Http.set_enabled(!!value)
        had_value = settings.key?(:http_enabled)
        previous = settings[:http_enabled]
        begin
          settings[:http_enabled] = !!value
          settings.commit
        rescue StandardError => e
          had_value ? settings[:http_enabled] = previous : settings.delete(:http_enabled)
          was_running ? ModLoader::Http.start(previous_port) : ModLoader::Http.stop
          puts "[InputSettings] could not save HTTP state: #{e.message}"
          return false
        end
        true
      end

      def valid_port?(value)
        value.is_a?(Integer) && value >= 1 && value <= 65535
      end

      def http_port
        saved = settings[:http_port]
        return saved if valid_port?(saved)
        configured = ModLoader.config_get("http_port") rescue nil
        valid_port?(configured) ? configured : DEFAULT_HTTP_PORT
      end

      def save_http_port(text)
        return false unless text.is_a?(String) && text =~ /\A[0-9]{1,5}\z/
        value = text.to_i
        return false unless valid_port?(value)
        previous = settings[:http_port]
        begin
          settings[:http_port] = value
          settings.commit
        rescue StandardError => e
          settings[:http_port] = previous
          puts "[InputSettings] could not save HTTP port: #{e.message}"
          return false
        end
        true
      end
    end
  end
end

if defined?(ModLoader::ModMenu) && defined?(ModLoader::TextInput::Line)
class ModLoader_HttpPortWindow < ModMenu_CommandWindow
  def initialize
    @line = ModLoader::TextInput::Line.new(:max_length => 5)
    @line.replace(ModLoader::InputSettings.http_port.to_s)
    super(0, 0)
    self.x = (Graphics.width - width) / 2
    self.y = (Graphics.height - height) / 2
    arm_input
  end

  def window_width; [360, Graphics.width - 24].min; end
  def visible_line_number; 1; end
  def make_command_list; add_command("HTTP port", :port); end
  def process_cursor_move; end

  def draw_item(index)
    reset_font_settings
    ModLoader::TextInput.draw(self, item_rect_for_text(index), @line,
      :prompt => ModLoader::ModMenu.tr("HTTP port") + ": ")
  end

  def description_text
    ModLoader::ModMenu.tr(@error || "Enter a port from 1 to 65535. Enter saves; Esc cancels. Applies the next time HTTP is enabled or the game restarts.")
  end

  def process_handling
    return unless input_ready?
    if vk_pressed?(K::ESC)
      Sound.play_cancel
      request_close
    elsif ModLoader::TextInput.update(@line)
      @error = nil
      redraw_current_item
    elsif vk_pressed?(K::RETURN)
      if ModLoader::InputSettings.save_http_port(@line.text)
        Sound.play_ok
        parent_window.redraw_current_item if parent_window
        request_close
      else
        @error = "Could not save. Enter a port from 1 to 65535; if it is valid, check the ModLoader log."
        Sound.play_buzzer
      end
    end
  end
end

module ModLoader
  module InputSettings
    class PortItem < ModMenu::WindowItem
      def draw(window, rect)
        @opts[:detail] = InputSettings.http_port.to_s
        super
      end
    end
  end
  ModMenu.category("Debug", :id => :modloader_input) do |menu|
    menu.header("Network")
    menu.toggle("HTTP server",
      :id => :http_enabled,
      :description => "Enable the local HTTP API for external tools. Off by default. Applies immediately and is saved for future launches.",
      :enabled => proc { InputSettings.http_available? },
      :get => proc { InputSettings.http_running? },
      :set => proc { |value|
        unless InputSettings.save_http_enabled(value)
          msgbox(ModMenu.tr("Could not change or save the HTTP server state. Check that the port is free and see the ModLoader log."))
        end
      })
    menu.register(InputSettings::PortItem.new("HTTP port",
      { :id => :http_port,
        :enabled => proc { ModLoader.respond_to?(:http_listen) },
        :description => "Type the HTTP server port (1-65535). Applies on the next HTTP enable or game launch; overrides http_port in mod_loader.json." },
      proc { ModLoader_HttpPortWindow.new }))
  end
end
end
end
