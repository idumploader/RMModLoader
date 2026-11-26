# Original RGSS and partner windows also use logical face crops.
# Borrow Cache.face sources; only Cache.clear owns their lifetime.
class Window_Base
  def draw_face(face_name, face_index, x, y, enabled = true)
    bitmap = Cache.face(face_name)
    contents.stretch_blt(Rect.new(x, y, 96, 96), bitmap,
      BSFaceSheet.rect(bitmap, face_index), enabled ? 255 : translucent_alpha)
  end
end

# Without HRFix the original message method still accepts a numeric size.
unless defined?(BSResolutionFix)
  class Window_Message
    def draw_face(face_name, face_index, x, y, size = 96)
      bitmap = Cache.face(face_name)
      contents.stretch_blt(Rect.new(x, y, size, size), bitmap,
        BSFaceSheet.rect(bitmap, face_index, 0, 0, size, size))
      show_name_window(face_name, face_index, x, size) if respond_to?(:show_name_window)
    end
  end
end

[:Window_SptActor, :Window_SptSpirit].each do |name|
  next unless Object.const_defined?(name)
  klass = Object.const_get(name)
  lines = name == :Window_SptActor ? 1 : 2
  klass.send(:define_method, :draw_face) do |face_name, face_index, x, y, enabled = true|
    bitmap = Cache.face(face_name)
    height = line_height * lines
    source = BSFaceSheet.rect(bitmap, face_index, 0, (96 - height) / 2, 96, height)
    contents.stretch_blt(Rect.new(x, y, 96, height), bitmap, source,
      enabled ? 255 : translucent_alpha)
  end
end
