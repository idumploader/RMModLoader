# Keep Game_Picture coordinates/scales in the original game's coordinate space.
# Apply resource density and screen transforms only to the displayed sprite.
module HRFix
  module Pictures
    def self.original_size(bitmap)
      bitmap.graphics_replace_original_size ||
        [bitmap.width, bitmap.height]
    end

    def self.fullscreen?(picture, bitmap)
      return false if bitmap.graphics_replace_original_known == false
      width, height = original_size(bitmap)
      width *= picture.zoom_x / 100.0
      height *= picture.zoom_y / 100.0
      return false if width <= 0 || height <= 0
      x, y = picture.x, picture.y
      if picture.origin == 1
        x -= width / 2.0
        y -= height / 2.0
      end
      x <= 1 && y <= 1 && x + width >= 639 && y + height >= 479
    end
  end
end

class Game_Picture
  attr_accessor :hrfix_fullscreen
  alias hrfix_picture_orig_show show
  def show(*args)
    self.hrfix_fullscreen = nil
    hrfix_picture_orig_show(*args)
  end
end

class Sprite_Picture
  alias hrfix_picture_orig_update update
  alias hrfix_picture_orig_dispose dispose

  def update
    hrfix_picture_orig_update
    if bitmap && !bitmap.disposed? && !@picture.name.empty?
      if @picture.hrfix_fullscreen.nil?
        @picture.hrfix_fullscreen = HRFix::Pictures.fullscreen?(@picture, bitmap)
      end
      width, height = HRFix::Pictures.original_size(bitmap)
      sx, sy = Graphics.width / 640.0, Graphics.height / 480.0
      offset_x = offset_y = 0.0
      if @picture.hrfix_fullscreen
        sx = sy = [sx, sy].min
        offset_x = (Graphics.width - 640 * sx) / 2.0
        offset_y = (Graphics.height - 480 * sy) / 2.0
      end
      self.x = offset_x + @picture.x * sx
      self.y = offset_y + @picture.y * sy
      self.zoom_x = @picture.zoom_x / 100.0 * sx * width / bitmap.width
      self.zoom_y = @picture.zoom_y / 100.0 * sy * height / bitmap.height
      hrfix_update_picture_bars(offset_x.round, offset_y.round)
    else
      hrfix_hide_picture_bars
    end
  end

  def hrfix_update_picture_bars(x, y)
    unless @picture.hrfix_fullscreen && (x > 0 || y > 0)
      hrfix_hide_picture_bars
      return
    end
    unless @hrfix_picture_bars
      @hrfix_bar_bitmap = Bitmap.new(1, 1)
      @hrfix_bar_bitmap.fill_rect(0, 0, 1, 1, Color.new(0, 0, 0, 255))
      @hrfix_picture_bars = Array.new(4) do
        bar = Sprite.new(viewport)
        bar.bitmap = @hrfix_bar_bitmap
        bar
      end
    end
    w, h = Graphics.width, Graphics.height
    rects = [[0, 0, x, h], [w - x, 0, x, h],
             [x, 0, w - 2 * x, y], [x, h - y, w - 2 * x, y]]
    @hrfix_picture_bars.each_with_index do |bar, index|
      bx, by, bw, bh = rects[index]
      bar.viewport = viewport
      bar.x, bar.y = bx, by
      bar.zoom_x, bar.zoom_y = bw, bh
      # Same z as the picture: bars are created later and cover lower pictures,
      # including an adjacent picture ID. They stay outside the fitted canvas.
      bar.z = self.z
      bar.opacity = self.opacity
      bar.visible = self.visible && bw > 0 && bh > 0
    end
  end

  def hrfix_hide_picture_bars
    @hrfix_picture_bars.each { |bar| bar.visible = false } if @hrfix_picture_bars
  end

  def dispose
    if @hrfix_picture_bars
      @hrfix_picture_bars.each { |bar| bar.dispose }
      @hrfix_bar_bitmap.dispose
      @hrfix_picture_bars = nil
    end
    hrfix_picture_orig_dispose
  end
end
