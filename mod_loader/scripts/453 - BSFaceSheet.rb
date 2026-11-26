# Faces retain their 4-column, 2-row index layout at any source resolution.
# Crop coordinates are authored in logical 96x96 units; UI sizes stay unchanged.
module BSFaceSheet
  def self.rect(bitmap, index, x = 0, y = 0, width = 96, height = 96)
    cell_width = bitmap.width / 4
    cell_height = bitmap.height / 2
    # The game also has square single-face files; Cache.face('') is blank 32x32.
    if bitmap.width == bitmap.height
      cell_width = cell_height = bitmap.width
      index = 0
    end
    left = (x * cell_width / 96.0).round
    top = (y * cell_height / 96.0).round
    right = ((x + width) * cell_width / 96.0).round
    bottom = ((y + height) * cell_height / 96.0).round
    Rect.new(index % 4 * cell_width + left, index / 4 * cell_height + top,
      right - left, bottom - top)
  end
end
