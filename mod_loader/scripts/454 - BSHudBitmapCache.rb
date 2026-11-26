# Owned derived HUD bitmaps; Cache.system/face sources remain borrowed.
# Ruby 1.9 / RGSS3 compatible. Callers borrow results only inside the block.
$imported ||= {}
unless $imported['BS-HudBitmapCache']
$imported['BS-HudBitmapCache'] = true
module BSHudBitmapCache
  LIMIT_BYTES = 8 * 1024 * 1024
  LIMIT_ENTRIES = 64
  @entries = {}
  @bytes = 0

  def self.clear
    @entries.each_value { |entry| entry[1].dispose unless entry[1].disposed? }
    @entries.clear
    @bytes = 0
    @resolution = nil
  end

  def self.remove(key)
    entry = @entries.delete(key)
    return unless entry
    @bytes -= entry[2]
    entry[1].dispose unless entry[1].disposed?
  end

  def self.borrow(key, source, width, height, builder)
    resolution = [Graphics.width, Graphics.height]
    clear if @resolution != resolution
    @resolution = resolution
    @entries.keys.each do |old_key|
      entry = @entries[old_key]
      remove(old_key) if (entry[0] && entry[0].disposed?) || entry[1].disposed?
    end
    key = key + [source, width, height]
    entry = @entries.delete(key)
    if entry
      @entries[key] = entry # Ruby ordered Hash provides LRU order.
      return yield(entry[1])
    end
    bitmap = Bitmap.new(width, height)
    retained = false
    begin
      builder.call(bitmap)
      bytes = width * height * 4
      if bytes <= LIMIT_BYTES
        remove(@entries.keys.first) while @bytes + bytes > LIMIT_BYTES || @entries.size >= LIMIT_ENTRIES
        @entries[key] = [source, bitmap, bytes]
        @bytes += bytes
        retained = true
      end
      yield bitmap
    ensure
      bitmap.dispose unless retained || bitmap.disposed?
    end
  end

  def self.artwork(name, scale, &block)
    source = Cache.system(name)
    return block.call(source) if scale == 1.0
    width = (source.width * scale).round
    height = (source.height * scale).round
    borrow([:artwork, name.dup.freeze], source, width, height,
      lambda { |bitmap| resample_artwork(bitmap, source) }, &block)
  end

  def self.resample_artwork(result, source)
    width = result.width; height = result.height
    # Keep the existing premultiplied-alpha bilinear calculation unchanged.
    height.times do |y|
      sy = [[(y + 0.5) * source.height / height - 0.5, 0].max, source.height - 1].min
      y0 = sy.floor; y1 = [y0 + 1, source.height - 1].min; fy = sy - y0
      width.times do |x|
        sx = [[(x + 0.5) * source.width / width - 0.5, 0].max, source.width - 1].min
        x0 = sx.floor; x1 = [x0 + 1, source.width - 1].min; fx = sx - x0
        samples = [[x0,y0,(1-fx)*(1-fy)], [x1,y0,fx*(1-fy)],
                   [x0,y1,(1-fx)*fy], [x1,y1,fx*fy]]
        alpha = red = green = blue = 0.0
        samples.each do |px, py, weight|
          c = source.get_pixel(px, py)
          a = c.alpha * weight
          alpha += a; red += c.red * a; green += c.green * a; blue += c.blue * a
        end
        if alpha > 0
          result.set_pixel(x, y, Color.new(red / alpha, green / alpha, blue / alpha, alpha))
        end
      end
    end
  end

  def self.portrait(name, index, size, &block)
    # RGSS Cache.face('') creates a fresh transparent Bitmap on every call.
    # A blank portrait needs neither that temporary source nor resampling.
    if name.empty?
      return borrow([:portrait, ''.freeze, index], nil, size, size,
        lambda { |_| }, &block)
    end
    source = Cache.face(name)
    borrow([:portrait, name.dup.freeze, index], source, size, size,
      lambda do |bitmap|
        rect = BSFaceSheet.rect(source, index)
        bitmap.stretch_blt(bitmap.rect, source, rect)
        corner = 22.0 / 48 * size
        size.times do |y|
          cut = [(corner - y - 0.5).ceil, (y + 0.5 - (size - corner)).ceil, 0].max
          bitmap.clear_rect(0, y, cut, 1) if cut > 0
          bitmap.clear_rect(size - cut, y, cut, 1) if cut > 0
        end
      end, &block)
  end

  def self.status
    { :entries => @entries.size, :bytes => @bytes,
      :limit_bytes => LIMIT_BYTES, :limit_entries => LIMIT_ENTRIES }
  end
end

# Cache invalidation also releases derived images. Lifecycle hook runs again
# after F12 even when imported scripts are not evaluated a second time.
original_clear = Cache.method(:clear)
Cache.singleton_class.send(:define_method, :clear) do
  BSHudBitmapCache.clear
  original_clear.call
end
original_run = SceneManager.method(:run)
SceneManager.singleton_class.send(:define_method, :run) do
  BSHudBitmapCache.clear
  begin
    original_run.call
  ensure
    BSHudBitmapCache.clear
  end
end
end
