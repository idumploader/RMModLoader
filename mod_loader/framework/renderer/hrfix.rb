#==============================================================================
# HRFix — high-resolution fix: rescales UI, pictures, parallaxes, enemies and
# the tilemap for screen sizes larger than the original 640x480.
#
# Passive — hooks engine classes (Game_Map scroll, Game_Interpreter picture
# commands 231/232, Spriteset_Map/Battle, Window_Base, Game_Troop). No user
# commands. Pictures use original resource dimensions and automatic fullscreen detection.
#
# Config gate:  ModLoader.hrfix_enabled
# Version note: on versions other than "2.4"/"2.5" also enables the tileset
#               offset feature (ModLoader.hrfix_tileset_offset_enabled).
#==============================================================================

$imported ||= {}
if not $imported["IDL-HRFix"]
$imported["IDL-HRFix"] = "1.0"

if ModLoader.hrfix_enabled

#Graphics.resize_screen(1920, 1080)

module HRFix
  ENABLE_PICTURE_RESIZING = true

end

class Spriteset_Map
  alias hrfix_orig_create_tilemap create_tilemap
  alias hrfix_orig_update_tilemap update_tilemap

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def create_tilemap
    @tilemap = Tilemap.new(@viewport1)
    @tilemap.map_data = $game_map.data
    @tilemap.map_id = $game_map.map_id # custom field, used by hook to identify map id
    load_tileset
  end

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def update_tilemap
    @tilemap.map_data = $game_map.data
    @tilemap.ox = $game_map.display_x * 32
    @tilemap.oy = $game_map.display_y * 32
    @tilemap.map_id = $game_map.map_id # custom field, used by hook to identify map id
    @tilemap.update
  end
end

class Game_Map
  alias hrfix_orig_scroll_down scroll_down
  alias hrfix_orig_scroll_left scroll_left
  alias hrfix_orig_scroll_right scroll_right
  alias hrfix_orig_scroll_up scroll_up

  alias hrfix_orig_set_display_pos set_display_pos

  def set_display_pos(x, y)
    hrfix_orig_set_display_pos(x, y)
    @display_y = [@display_y, 0].max
    @display_x = [@display_x, 0].max
  end

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def scroll_down(distance)
    if loop_vertical?
      @display_y += distance
      @display_y %= @map.height
      @parallax_y += distance if @parallax_loop_y
    else
      last_y = @display_y
      @display_y = [[@display_y + distance, height - screen_tile_y].min, 0].max  # fixes scroll bug with bigger Graphics size
      @parallax_y += @display_y - last_y
    end
  end

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def scroll_left(distance)
    if loop_horizontal?
      @display_x += @map.width - distance
      @display_x %= @map.width
      @parallax_x -= distance if @parallax_loop_x
    else
      last_x = @display_x
      @display_x = [[@display_x - distance, 0].max, width].min
      @parallax_x += @display_x - last_x
    end
  end

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def scroll_right(distance)
    if loop_horizontal?
      @display_x += distance
      @display_x %= @map.width
      @parallax_x += distance if @parallax_loop_x
    else
      last_x = @display_x
      @display_x = [[@display_x + distance, (width - screen_tile_x)].min, 0].max # fixes scroll bug with bigger Graphics size
      @parallax_x += @display_x - last_x
    end
  end

  # WARNING: COPIED SOURCE FROM RPG MAKER
  def scroll_up(distance)
    if loop_vertical?
      @display_y += @map.height - distance
      @display_y %= @map.height
      @parallax_y -= distance if @parallax_loop_y
    else
      last_y = @display_y
      @display_y = [[@display_y - distance, 0].max, height].min
      @parallax_y += @display_y - last_y
    end
  end
end

if HRFix::ENABLE_PICTURE_RESIZING
  ModLoader::Framework.load('renderer/hrfix_pictures.rb')
end

class Window_Base
  alias hrfix_orig_draw_item_name draw_item_name

  def draw_item_name(item, x, y, enabled = true, width = 0)
    width = self.width * 0.75 if width.zero? # fixes item name cropping
    hrfix_orig_draw_item_name(item, x, y, enabled, width)
  end
end

class Game_Troop
  alias hrfix_orig_setup setup

  def setup(troop_id)
    hrfix_orig_setup(troop_id)
    @enemies.each do |enemy|
      enemy.screen_x *= Graphics.width / 640.0 # Fixes monster position
      enemy.screen_y *= Graphics.height / 480.0 # Fixes monster position
    end
  end
end

class Spriteset_Battle

  # WARNING: Copied from RPG Maker
  def create_blurry_background_bitmap
    source = SceneManager.background_bitmap
    bitmap = Bitmap.new(Graphics.width, Graphics.height)
    bitmap.stretch_blt(bitmap.rect, source, source.rect)
    bitmap.radial_blur(120, 16)
    bitmap
  end

end

# class Window_Message
  # def window_width
    # [Graphics.width, 640].min
  # end

  # def update_placement
    # @position = $game_message.position
    # self.y = @position * (Graphics.height - height) / 2
    # @gold_window.y = y > 0 ? 0 : Graphics.height - @gold_window.height

    # self.x = (Graphics.width - window_width) / 2
  # end
# end

# class Window_FaceName

  # def hrfix_update_placement
      # @name_sprite.x = self.x + self.width / 2
    # @name_sprite.y = self.y + self.height / 2
  # end
# end

# class Window_Base

  # alias hrfix_orig_show_name_window show_name_window

  # def show_name_window(face_name, face_index, x, size = 96)
    # hrfix_orig_show_name_window(face_name, face_index, x, size)
    # # @name_windows[name].x += [0, 640 - Graphics.width].max / 2
    # @name_windows.each do |key, window|
      # window.x += [0, Graphics.width - 640].max / 2
      # p window.x
      # window.hrfix_update_placement
    # end
  # end

# end

class Game_Character

  attr_accessor :x
  attr_accessor :y
  attr_accessor :real_x
  attr_accessor :real_y

end

# class Spriteset_Map
  # attr_reader :tilemap

  # alias hrfix_orig_create_characters create_characters
  # alias hrfix_orig_create_viewports create_viewports
  # alias hrfix_orig_create_parallax create_parallax
  # alias hrfix_orig_update_viewports update_viewports

  # def create_viewports
    # hrfix_orig_create_viewports
    # @tm_viewport = Viewport.new
    # @viewport1.z = 1
  # end

  # def create_tilemap
    # @tilemap = Tilemap.new(@tm_viewport)
    # @tilemap.map_data = $game_map.data
    # load_tileset
  # end

  # def create_parallax
    # @parallax = Plane.new(@tm_viewport)
    # @parallax.z = -100
  # end

  # def create_characters
    # hrfix_orig_create_characters

    # off_x = [$game_map.screen_tile_x - $game_map.width, 0].max * 16
    # off_y = [$game_map.screen_tile_y - $game_map.height, 0].max * 16
    # # @character_sprites.each do |sprite|
    # #  sprite.character.real_x += off_x
    # #  sprite.character.real_y += off_y
    # # end

    # @viewport1.x = off_x
    # @viewport1.y = off_y
  # end

  # def update_characters
    # refresh_characters if @map_id != $game_map.map_id

    # off_x = [$game_map.screen_tile_x - $game_map.width, 0].max * 16
    # off_y = [$game_map.screen_tile_y - $game_map.height, 0].max * 16
    # @character_sprites.each do |sprite|
      # sprite.update
      # # sprite.x += off_x
      # # sprite.y += off_y
    # end
  # end

  # def update_viewports
    # hrfix_orig_update_viewports
    # @tm_viewport.update
  # end
# end

if not ["2.4", "2.5"].include?(ModLoader.version)

p "HRFix: ModLoader.version >= 2.6. Enabled hrfix_tileset_offset_enabled"

class Scene_Map

  alias hrfix_orig_start start
  alias hrfix_orig_terminate terminate

  def start
    ModLoader.hrfix_tileset_offset_enabled = true
    hrfix_orig_start
  end

  def terminate
    ModLoader.hrfix_tileset_offset_enabled = false
    hrfix_orig_terminate
  end

end

class Scene_Title
  alias hrfix_orig_start start

  def start
    ModLoader.hrfix_tileset_offset_enabled = false
    hrfix_orig_start
  end
end

end # not ["2.4", "2.5"].include?(ModLoader.version)

class Game_Event
  alias hrfix_orig_near_the_screen? :near_the_screen?

  def near_the_screen?(dx = $game_map.screen_tile_x / 2 + 1, dy = $game_map.screen_tile_y / 2 + 1)
    hrfix_orig_near_the_screen?(dx, dy)
  end
end

end # ModLoader.hrfix_enabled

end # not $imported["IDL-HRFix"]