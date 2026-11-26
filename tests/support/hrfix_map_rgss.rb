# Small RGSS fixture: the camera/loop equations are the engine's, so changing
# screen_tile_x/y must affect scrolling without replacing those algorithms.
module Graphics
  def self.width; 1280; end
  def self.height; 960; end
end
module ModLoader
  def self.hrfix_enabled; true; end
  def self.hrfix_settings(pending); [1280, 960, ENV['HRFIX_TEST_MAP'] != 'render']; end
end
class Game_Map
  attr_accessor :width, :height, :loop_x, :loop_y
  attr_reader :display_x, :display_y
  def initialize(w = 100, h = 80)
    @width, @height = w, h
    @display_x = @display_y = @parallax_x = @parallax_y = 0
  end
  def parallax_ox(bitmap); 123; end
  def parallax_oy(bitmap); 456; end
  def screen_tile_x; Graphics.width / 32; end
  def screen_tile_y; Graphics.height / 32; end
  def set_display_pos(x, y)
    @display_x = @loop_x ? x % width : [[x, width - screen_tile_x].min, 0].max
    @display_y = @loop_y ? y % height : [[y, height - screen_tile_y].min, 0].max
    @parallax_x, @parallax_y = x, y
  end
  def scroll_right(d); set_display_pos(@display_x + d, @display_y); end
  def scroll_down(d); set_display_pos(@display_x, @display_y + d); end
  def adjust_x(x)
    @loop_x && x < @display_x - (width - screen_tile_x) / 2 ? x - @display_x + width : x - @display_x
  end
end
class Game_Player
  attr_accessor :x, :y
  def center_x; (Graphics.width / 32 - 1) / 2.0; end
  def center_y; (Graphics.height / 32 - 1) / 2.0; end
  def center(x, y); $game_map.set_display_pos(x - center_x, y - center_y); end
end
class Game_System
  attr_reader :loaded
  def on_after_load; @loaded = true; end
end
class Viewport
  attr_reader :source, :disposed
  def source_size(w, h); @source = [w, h]; end
  def dispose; @disposed = true; end
end
class Spriteset_Weather
  attr_reader :original_calls
  def initialize; @ox = @oy = 0; @sprites = []; end
  def add_sprite; @sprites << Struct.new(:viewport, :z).new; end
  def create_new_particle(sprite); @original_calls = (@original_calls || 0) + 1; end
end
class Spriteset_Map
  attr_reader :viewport1, :viewport2, :viewport3, :weather
  def create_viewports; @viewport1, @viewport2, @viewport3 = Viewport.new, Viewport.new, Viewport.new; end
  def dispose_viewports; [@viewport1, @viewport2, @viewport3].each { |v| v.dispose }; end
  def create_weather; @weather = Spriteset_Weather.new; end
end

class Game_Event
  def near_the_screen?(dx = 1, dy = 1); true; end
end
