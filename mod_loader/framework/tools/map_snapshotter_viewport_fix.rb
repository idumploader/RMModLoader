#==============================================================================
# MapSnapshotter Viewport Fix
#------------------------------------------------------------------------------
# Reacquires the live Spriteset_Map viewports before every tile.  Developer
# maptp can replace/dispose a spriteset between captures; retaining @viewport
# from begin_capture would then crash with "RGSSError: disposed viewport".
#
# viewport2 is lifted together with viewport1 so RichFog is present in beacon
# captures.  HUD/windows on the default viewport remain hidden by the z mask.
#==============================================================================

$imported ||= {}
if not $imported["IDL-MapSnapshotter-ViewportFix"] and
   defined?(MapSnapshotter)
$imported["IDL-MapSnapshotter-ViewportFix"] = "1.0"

module MapSnapshotter
  class << self
    def msnap_live_viewports
      scene = SceneManager.scene
      spriteset = scene && scene.instance_variable_get(:@spriteset)
      viewport1 = spriteset && spriteset.instance_variable_get(:@viewport1)

      if (viewport1.nil? || viewport1.disposed?) &&
         scene && scene.respond_to?(:create_spriteset, true)
        scene.send(:create_spriteset)
        spriteset = scene.instance_variable_get(:@spriteset)
        viewport1 = spriteset && spriteset.instance_variable_get(:@viewport1)
      end

      viewport2 = spriteset && spriteset.instance_variable_get(:@viewport2)
      viewport2 = nil if viewport2 && viewport2.disposed?
      [viewport1, viewport2]
    end

    def snap_map_only
      viewport1, viewport2 = msnap_live_viewports
      if viewport1.nil? || viewport1.disposed?
        raise RGSSError, "MapSnapshotter has no live map viewport"
      end

      @viewport = viewport1
      z1 = viewport1.z
      z2 = viewport2 ? viewport2.z : nil
      cover = Sprite.new
      cover.bitmap = Bitmap.new(1, 1)
      cover.bitmap.set_pixel(0, 0, Color.new(0, 0, 0))
      cover.zoom_x = Graphics.width
      cover.zoom_y = Graphics.height
      cover.z = 0x0FFF_FFFF

      begin
        viewport1.z = 0x2FFF_FFFF
        viewport2.z = 0x3000_0000 if viewport2
        Graphics.snap_to_bitmap
      ensure
        viewport1.z = z1 unless viewport1.disposed?
        viewport2.z = z2 if viewport2 && !viewport2.disposed?
        cover.bitmap.dispose if cover.bitmap && !cover.bitmap.disposed?
        cover.dispose unless cover.disposed?
      end
    end
  end
end

# Opening the pause/menu scene while a tile batch is active disposes the map
# viewport underneath MapSnapshotter.  Ignore only the menu call for those few
# capture frames; normal Esc behaviour is untouched before and after a shot.
if defined?(Scene_Map)
  class Scene_Map < Scene_Base
    unless method_defined?(:msnap_viewport_fix_orig_update_call_menu)
      alias_method :msnap_viewport_fix_orig_update_call_menu, :update_call_menu
    end

    def update_call_menu
      return if MapSnapshotter.active? || MapSnapshotter.pending?
      msnap_viewport_fix_orig_update_call_menu
    end
  end
end

puts "[MapSnapshotter] live viewport + RichFog fix registered"

end
