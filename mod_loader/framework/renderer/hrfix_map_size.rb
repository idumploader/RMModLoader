# Keep map coordinates and camera at the original size while the native
# viewport compositor enlarges only the map layer. Pictures/windows retain
# HRFix's internal resolution. Runtime setting: never stored in game saves.
$imported ||= {}
unless $imported["IDL-HRFixMapSize"]
$imported["IDL-HRFixMapSize"] = "1.0"

# This extension requires the new native HRFix/viewport API.
if ModLoader.respond_to?(:hrfix_settings) && ModLoader.hrfix_enabled
module HRFix
  module MapSize
    WIDTH = 640
    HEIGHT = 480
    @original = ModLoader.hrfix_settings(false)[2]
    def self.refresh; @original = ModLoader.hrfix_settings(false)[2]; end
    def self.original?; @original; end
    def self.width; original? ? WIDTH : Graphics.width; end
    def self.height; original? ? HEIGHT : Graphics.height; end
  end
end

class Game_Map
  alias hrfix_mapsize_parallax_ox parallax_ox
  alias hrfix_mapsize_parallax_oy parallax_oy
  def screen_tile_x; HRFix::MapSize.width / 32; end
  def screen_tile_y; HRFix::MapSize.height / 32; end

  def parallax_ox(bitmap)
    return hrfix_mapsize_parallax_ox(bitmap) unless HRFix::MapSize.original?
    return @parallax_x * 16 if @parallax_loop_x
    span = [bitmap.width - HRFix::MapSize.width, 0].max
    distance = [width * 32 - HRFix::MapSize.width, 1].max
    @parallax_x * 16 * span / distance
  end

  def parallax_oy(bitmap)
    return hrfix_mapsize_parallax_oy(bitmap) unless HRFix::MapSize.original?
    return @parallax_y * 16 if @parallax_loop_y
    span = [bitmap.height - HRFix::MapSize.height, 0].max
    distance = [height * 32 - HRFix::MapSize.height, 1].max
    @parallax_y * 16 * span / distance
  end
end

class Game_Player
  def center_x; (HRFix::MapSize.width / 32 - 1) / 2.0; end
  def center_y; (HRFix::MapSize.height / 32 - 1) / 2.0; end
end

class Game_Event
  alias hrfix_mapsize_near_the_screen near_the_screen?
  # Autonomous routes (including rotating item markers) use map coordinates.
  # Graphics.width/height describe the enlarged output, not this 640x480 layer.
  def near_the_screen?(dx = $game_map.screen_tile_x / 2 + 1, dy = $game_map.screen_tile_y / 2 + 1)
    return hrfix_mapsize_near_the_screen(dx, dy) unless HRFix::MapSize.original?
    ax = $game_map.adjust_x(@real_x) - HRFix::MapSize.width / 2 / 32
    ay = $game_map.adjust_y(@real_y) - HRFix::MapSize.height / 2 / 32
    ax >= -dx && ax <= dx && ay >= -dy && ay <= dy
  end
end

class Game_System
  alias hrfix_mapsize_on_after_load on_after_load
  def on_after_load
    hrfix_mapsize_on_after_load
    # A save may contain the camera position from another render resolution.
    $game_player.center($game_player.x, $game_player.y)
  end
end

class Spriteset_Weather
  attr_accessor :hrfix_original_map_size
  def hrfix_map_viewport=(viewport)
    @hrfix_map_viewport = viewport
    @sprites.each do |sprite|
      sprite.viewport = viewport
      sprite.z = 0x8000
    end
  end
  alias hrfix_mapsize_add_sprite add_sprite
  def add_sprite
    hrfix_mapsize_add_sprite
    if @hrfix_map_viewport
      @sprites[-1].viewport = @hrfix_map_viewport
      @sprites[-1].z = 0x8000
    end
  end
  alias hrfix_mapsize_create_new_particle create_new_particle
  def create_new_particle(sprite)
    return hrfix_mapsize_create_new_particle(sprite) unless @hrfix_original_map_size
    sprite.x = rand(HRFix::MapSize.width + 100) - 100 + @ox
    sprite.y = rand(HRFix::MapSize.height + 200) - 200 + @oy
    sprite.opacity = 160 + rand(96)
  end
end

class Spriteset_Map
  alias hrfix_mapsize_create_weather create_weather
  def create_weather
    hrfix_mapsize_create_weather
    if HRFix::MapSize.original?
      @weather.hrfix_original_map_size = true
      @weather.hrfix_map_viewport = @viewport1
    end
  end

  alias hrfix_mapsize_create_viewports create_viewports
  def create_viewports
    hrfix_mapsize_create_viewports
    @viewport1.source_size(HRFix::MapSize.width, HRFix::MapSize.height) if HRFix::MapSize.original?
  end

  alias hrfix_mapsize_dispose_viewports dispose_viewports
  def dispose_viewports
    @viewport1.source_size(0, 0)
    hrfix_mapsize_dispose_viewports
  end
end
end
end
