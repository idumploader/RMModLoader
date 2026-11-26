# Shared single-line editing for mod windows. The owner handles focus, capture,
# submission and history; drawing uses its existing RGSS contents and font.
$imported ||= {}
unless $imported['IDL-ModLoaderLineInput']
$imported['IDL-ModLoaderLineInput'] = '1.0'

module ModLoader
  module TextInput
    class Line
      attr_reader :text, :cursor, :revision

      def initialize(options = {})
        @max_length = options[:max_length]
        @text = ''.freeze
        @cursor = @revision = @view_start = 0
      end

      def replace(text)
        text = clean(text)
        text = text[0, @max_length] if @max_length
        set_text(text, text.length)
      end

      def insert(text)
        text = clean(text)
        text = text[0, @max_length - @text.length] if @max_length
        set_text(@text[0...@cursor] + text + @text[@cursor..-1], @cursor + text.length)
      end

      def seek(position)
        set_text(@text, [[position, 0].max, @text.length].min)
      end

      def backspace
        return self if @cursor == 0
        set_text(@text[0...(@cursor - 1)] + @text[@cursor..-1], @cursor - 1)
      end

      def delete
        return self if @cursor == @text.length
        set_text(@text[0...@cursor] + @text[(@cursor + 1)..-1], @cursor)
      end

      # Return the visible slice and caret offset in pixels. Measuring is supplied
      # by the window, so scrolling follows its font and current available width.
      def view(width, &measure)
        @view_start = [@view_start, @cursor].min
        if measure.call(@text[@view_start..-1]) <= width
          # Deleting the tail reveals the hidden prefix as space becomes available.
          @view_start = fitting_start(@text.length, width, &measure)
        else
          @view_start = [@view_start, fitting_start(@cursor, width, &measure)].max
        end
        last = fitting_end(@view_start, width, &measure)
        [@text[@view_start...last], measure.call(@text[@view_start...@cursor])]
      end

      private

      def clean(text)
        text.gsub(/\r\n?|\n|\t/, ' ').gsub(/[[:cntrl:]]/, '')
      end

      def set_text(text, cursor)
        return self if @text == text && @cursor == cursor
        # Immutable snapshots prevent callers and recalled history from changing
        # the draft without updating its cursor/revision.
        @text = text.freeze
        @cursor = cursor
        @revision += 1
        self
      end

      def fitting_start(limit, width, &measure)
        low, high = 0, limit
        while low < high
          middle = (low + high) / 2
          if measure.call(@text[middle...limit]) <= width
            high = middle
          else
            low = middle + 1
          end
        end
        low
      end

      def fitting_end(start, width, &measure)
        low, high = start, @text.length
        while low < high
          middle = (low + high + 1) / 2
          if measure.call(@text[start...middle]) <= width
            low = middle
          else
            high = middle - 1
          end
        end
        low
      end
    end

    # True means an editing key/chord was handled, even at a boundary or with an
    # unavailable clipboard. Owners must not also submit in that frame. Use the
    # line's revision to detect changes to either text or caret for redraws.
    def self.update(line)
      k = ModLoader::Keyboard
      if ModLoader.input_press?(k::CTRL) && !ModLoader.input_press?(k::ALT)
        if ModLoader.input_trigger?(k::C)
          ModLoader::Clipboard.write(line.text)
          return true
        elsif ModLoader.input_trigger?(k::V)
          text = ModLoader::Clipboard.read
          line.insert(text) if text
          return true
        end
      end

      handled = false
      [k::BACK, k::DELETE, k::LEFT, k::RIGHT, k::HOME, k::END].each do |key|
        pressed = [k::HOME, k::END].include?(key) ? ModLoader.input_trigger?(key) : ModLoader.input_repeat?(key)
        next unless pressed
        case key
        when k::BACK; line.backspace
        when k::DELETE; line.delete
        when k::LEFT; line.seek(line.cursor - 1)
        when k::RIGHT; line.seek(line.cursor + 1)
        when k::HOME; line.seek(0)
        when k::END; line.seek(line.text.length)
        end
        handled = true
      end
      # Exclude control/function/navigation keys. OEM keys include punctuation.
      ([k::SPACE] + (0x30..0x5A).to_a + (0x60..0x6F).to_a + (0xBA..0xE2).to_a).each do |key|
        next unless ModLoader.input_trigger?(key)
        character = self.character(key)
        next if character.empty?
        line.insert(character)
        handled = true
      end
      handled
    end

    def self.draw(window, rect, line, options = {})
      return if rect.width <= 0 || rect.height <= 0
      prompt = options[:prompt] || ''
      prompt_width = prompt.empty? ? 0 : [window.text_size(prompt).width + 4, rect.width].min
      window.draw_text(rect.x, rect.y, prompt_width, rect.height, prompt) unless prompt.empty?
      x, width = rect.x + prompt_width, rect.width - prompt_width
      caret_width = options[:caret_width] || 2
      reserved_width = [caret_width + 2, 4].max
      return if width < reserved_width
      # Reserve the caret and glyph outline; draw plain text at its natural size.
      visible, offset = line.view(width - reserved_width) { |text| window.text_size(text).width }
      window.draw_text(x, rect.y, width, rect.height, visible)
      font = window.contents.font
      height = [options[:caret_height] || font.size, rect.height].min
      window.contents.fill_rect(x + offset, rect.y + (rect.height - height) / 2,
                                caret_width, height, options[:caret_color] || font.color)
    end
  end
end

end
