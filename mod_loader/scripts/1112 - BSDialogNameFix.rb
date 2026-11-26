# Name labels are separate sprites, so message contents font scaling misses them.
if defined?(Window_FaceName)
module BSDialogNameFix
  def self.pixels(value)
    return value unless ModLoader.hrfix_enabled
    scale = [[Graphics.width / 640.0, Graphics.height / 480.0].min, 1.0].max
    (value * scale).round
  end
end

module Cache
  def self.load_name_bitmap(name)
    @cache ||= {}
    size = [BSDialogNameFix.pixels(20), 96].min
    fonts = ['Lolita', *Font.default_name]
    margin = BSDialogNameFix.pixels(8)
    key = [name, 'bs_dialog_name', size, margin, fonts]
    return @cache[key] if include?(key)
    probe = Bitmap.new(1, 1)
    begin
      probe.font.name = fonts
      probe.font.size = size
      width = probe.text_size(name).width + margin
    ensure
      probe.dispose
    end
    bitmap = Bitmap.new(width, size + BSDialogNameFix.pixels(4))
    bitmap.font.name = fonts
    bitmap.font.size = size
    bitmap.font.color = Color.new(255, 255, 255)
    bitmap.draw_text(bitmap.rect, name, 1)
    @cache[key] = bitmap
  end
end

class Window_FaceName
  def create_name_sprite(name)
    if @name_sprite
      @name_sprite.bitmap.dispose unless @name_sprite.bitmap.disposed?
      @name_sprite.dispose
    end
    # The original window disposes its bitmap. Give each window an owned clone.
    bitmap = Cache.name_bitmap(name).clone
    @name_sprite = Sprite.new
    @name_sprite.bitmap = bitmap
    @name_sprite.ox = bitmap.width / 2
    @name_sprite.oy = bitmap.height / 2
    @name_sprite.visible = false
    margin = BSDialogNameFix.pixels(8)
    [bitmap.width + margin, bitmap.height + margin]
  end
end

class Window_Message
  def show_name_window(face_name, face_index, x, size = 96)
    return unless use_name_window?
    # show_name consumes the one-shot name/index, so resolve it exactly once.
    name = show_name(face_name, face_index)
    return if name.nil? || name.empty?
    label = (@name_windows[name] ||= Window_FaceName.new(name, self.z + 10))
    if x <= Graphics.width / 2
      label.x = self.x + x + size + BSDialogNameFix.pixels(20)
      if A1_System::NameWindow::FIX_LONG_NAME && label.x + label.width > Graphics.width / 2
        label.x = 0
      end
    else
      label.x = self.x + self.width - size - label.width
      if A1_System::NameWindow::FIX_LONG_NAME && label.x < Graphics.width / 2
        label.x = Graphics.width - label.width
      end
    end
    label.x = [[label.x, 0].max, [Graphics.width - label.width, 0].max].min
    # Attach to the border, overlapping only padding, never dialogue contents.
    above = self.y + self.padding - label.height
    label.y = above >= 0 ? above : self.y + self.height - self.padding
    label.openness = 255 if self.open?
    label.open
    label.visible = true
  end
end
end
