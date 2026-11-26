# ModLoader TextInput — printable UTF-8 input for chat, console and other editors.
# Uses the active Windows keyboard layout; key detection/editing belongs to callers.
# character(vk) returns UTF-8 text, or an empty string for dead/control keys.
$imported ||= {}
unless $imported["IDL-ModLoaderTextInput"]
$imported["IDL-ModLoaderTextInput"] = "1.0"

module ModLoader
  module TextInput
    def self.character(key)
      @state_api ||= Win32API.new('user32', 'GetKeyboardState', 'p', 'i')
      @text_api ||= Win32API.new('user32', 'ToUnicode', ['i', 'i', 'p', 'p', 'i', 'i'], 'i')
      state = "\0" * 256
      return '' if @state_api.call(state) == 0
      buffer = "\0" * 16
      count = @text_api.call(key, 0, state, buffer, 8, 0)
      return '' if count <= 0
      buffer[0, count * 2].force_encoding('UTF-16LE').encode('UTF-8').gsub(/[[:cntrl:]]/, '')
    end
  end
end
end
