#==============================================================================
# BSMP UI — part 4/5: on-screen widgets. Window (top-right backdrop base),
# Timed_Window (auto-fading) and Progress_Window (caption + progress bar, used
# by the save-transfer UI). See 1200 - BSMP Core.rb.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-UI"]
$imported["IDL-BSMP-UI"] = "1.0"

if defined?(BSMP)

module BSMP

  class Window < Window_Base
    Z          = 188
    MARGIN_X   = 16
    BACK_COLOR = Color.new(0, 42, 102, 160)

    def initialize
      super(Graphics.width - window_width - MARGIN_X, 0, window_width, window_height)
      self.z = Z
      self.opacity = 0
      self.back_opacity = 0

      self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)
    end

    def window_height
      return line_height * 2
    end

    def window_width
      return Graphics.width / 2
    end

    def update

    end
  end

  class Timed_Window < Window

    TIME_FRAMES = 180
    OPACITY     = 32

    def initialize
      super
      @frame_count = 0
    end

    def update
      super
      @frame_count += 1
      if @frame_count >= TIME_FRAMES
        self.contents_opacity -= OPACITY
        dispose if self.contents_opacity == 0
      end
    end

    def refresh(caption, text = "")

    end
  end

  class Progress_Window < Window

    PROGRESS_HEIGHT = 5
    NOPROGRESS_COLOR = Color.new(200, 200, 200, 255)
    PROGRESS_COLOR = Color.new(136, 8, 8, 255)

    attr_reader :progress
    attr_reader :text

    def initialize
      super
      self.progress = 0.0
      @window_changed = false
    end

    def update
      super
      if @window_changed
        update_window_size
        update_progress
        @window_changed = false
      end
    end

    def window_height
      return line_height * 3 + 5 if @text
      return line_height * 2
    end

    def text=(text)
      @text = text
      @window_changed = true
    end

    def progress=(progress)
      @progress = progress
      @window_changed = true
    end

    def update_progress
      self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)

      off_y = line_height / 2
      if @text
        draw_text(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, line_height, @text)
        off_y += line_height + 5
      end
      @progress = [1.0, @progress].min
      self.contents.fill_rect(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, PROGRESS_HEIGHT, NOPROGRESS_COLOR)
      self.contents.fill_rect(MARGIN_X, off_y, self.contents.width * @progress - MARGIN_X * 2, PROGRESS_HEIGHT, PROGRESS_COLOR)
    end

    def update_window_size
      old_height = self.height
      self.height = window_height
      create_contents if old_height != self.height
    end

  end

end # module BSMP

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-UI"]
