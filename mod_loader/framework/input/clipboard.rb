# Unicode clipboard access shared by ModLoader editors. Native calls are lazy;
# RGSS is a 32-bit Windows process, so Win32 handles/pointers use 32-bit longs.
$imported ||= {}
unless $imported['IDL-ModLoaderClipboard']
$imported['IDL-ModLoaderClipboard'] = '1.0'

module ModLoader
  module Clipboard
    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 2
    MAX_READ_BYTES = 1024 * 1024
    FUNCTIONS = {
      :active_window => ['user32', 'GetActiveWindow', '', 'l'],
      :open => ['user32', 'OpenClipboard', 'l', 'i'],
      :close => ['user32', 'CloseClipboard', '', 'i'],
      :get => ['user32', 'GetClipboardData', 'i', 'l'],
      :empty => ['user32', 'EmptyClipboard', '', 'i'],
      :set => ['user32', 'SetClipboardData', 'il', 'l'],
      :alloc => ['kernel32', 'GlobalAlloc', 'il', 'l'],
      :free => ['kernel32', 'GlobalFree', 'l', 'l'],
      :size => ['kernel32', 'GlobalSize', 'l', 'l'],
      :lock => ['kernel32', 'GlobalLock', 'l', 'l'],
      :unlock => ['kernel32', 'GlobalUnlock', 'l', 'i'],
      :read_memory => ['kernel32', 'RtlMoveMemory', 'pll', 'v'],
      :write_memory => ['kernel32', 'RtlMoveMemory', 'lpl', 'v']
    }

    def self.call(name, *args)
      @functions ||= {}
      function = (@functions[name] ||= Win32API.new(*FUNCTIONS.fetch(name)))
      function.call(*args)
    end

    def self.with_clipboard
      hwnd = call(:active_window)
      return nil if hwnd == 0 || call(:open, hwnd) == 0
      begin
        yield
      ensure
        call(:close)
      end
    end

    # nil means busy/unavailable/non-text. Borrowed memory belongs to Windows;
    # copy it while locked and always unlock it before closing the clipboard.
    def self.read
      with_clipboard do
        handle = call(:get, CF_UNICODETEXT)
        next nil if handle == 0
        size = call(:size, handle)
        next nil unless size >= 2 && size <= MAX_READ_BYTES
        pointer = call(:lock, handle)
        next nil if pointer == 0
        begin
          buffer = "\0" * size
          call(:read_memory, buffer, pointer, size)
          units = buffer.unpack('v*')
          ending = units.index(0)
          next nil unless ending
          units.first(ending).pack('v*').force_encoding('UTF-16LE').
            encode('UTF-8', :invalid => :replace, :undef => :replace)
        ensure
          call(:unlock, handle)
        end
      end
    end

    # Only SetClipboardData success transfers ownership to Windows. Allocate and
    # fill first so an allocation failure leaves the existing clipboard intact.
    def self.write(text)
      bytes = text.encode('UTF-16LE').force_encoding('ASCII-8BIT') + "\0\0"
      handle = call(:alloc, GMEM_MOVEABLE, bytes.bytesize)
      return false if handle == 0
      transferred = false
      begin
        pointer = call(:lock, handle)
        return false if pointer == 0
        begin
          call(:write_memory, pointer, bytes, bytes.bytesize)
        ensure
          call(:unlock, handle)
        end
        with_clipboard do
          next if call(:empty) == 0
          transferred = call(:set, CF_UNICODETEXT, handle) != 0
        end
        transferred
      ensure
        call(:free, handle) unless transferred
      end
    end
  end
end
end
