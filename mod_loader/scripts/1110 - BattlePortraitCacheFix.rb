# Cache.face owns the shared bitmap. Drawing a battle portrait must not dispose
# it: doing so forces another image load at every battle-status refresh.
# Keep the original game's crop and signature; Cache.clear handles lifetime.
# Requires the game's ED crop constants and Window_Base.draw_battle_face.
# Load after the original battle portrait script. Default ON; the Optimizations
# menu saves this choice in NVRAM and restores it at restart/F12. OFF calls the
# original method for standard sheets. HD sheets use an equivalent scaled crop
# and retain the OFF disposal behavior. No bitmap is owned by this fix.
$imported ||= {}
unless $imported["IDL-BattlePortraitCacheFix"]
module BattlePortraitCacheFix
  class << self
    attr_accessor :enabled
    def installed?; Window_Base.method_defined?(:battle_portrait_original_draw); end
  end
  self.enabled = true
end
if defined?(ED::BTL_FACE_RECT_X) &&
    defined?(ED::BTL_FACE_RECT_Y) && defined?(ED::BTL_FACE_RECT_WIDTH) &&
    defined?(ED::BTL_FACE_RECT_HEIGHT) &&
    Window_Base.method_defined?(:draw_battle_face)
  class Window_Base
    alias battle_portrait_original_draw draw_battle_face
    def draw_battle_face(face_name, face_index, x, y, size = 96)
      bitmap = Cache.face(face_name)
      unless BattlePortraitCacheFix.enabled || bitmap.width != 384 || bitmap.height != 192
        return battle_portrait_original_draw(face_name, face_index, x, y, size)
      end
      rect = BSFaceSheet.rect(bitmap, face_index, ED::BTL_FACE_RECT_X,
        ED::BTL_FACE_RECT_Y, ED::BTL_FACE_RECT_WIDTH, ED::BTL_FACE_RECT_HEIGHT)
      if bitmap.width == 384 && bitmap.height == 192
        contents.blt(x, y, bitmap, rect)
      else
        contents.stretch_blt(Rect.new(x, y, ED::BTL_FACE_RECT_WIDTH,
          ED::BTL_FACE_RECT_HEIGHT), bitmap, rect)
        bitmap.dispose unless BattlePortraitCacheFix.enabled
      end
    end
  end
  $imported["IDL-BattlePortraitCacheFix"] = "1.0"
end
end
