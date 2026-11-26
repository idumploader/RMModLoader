require 'minitest/autorun'
require 'ostruct'

# Minimal RGSS surface: update dispatch and window ownership behave like
# Window_Selectable/Window_Command; rendering calls are inert in host Ruby.
module ModLoader
  module Keyboard
    [:F10, :RETURN, :SPACE, :ESC, :UP, :DOWN, :LEFT, :RIGHT,
     :W, :A, :S, :D, :Q, :E, :NEXT, :PRIOR].each_with_index { |key, i| const_set(key, i + 8) }
  end
  class Section < Hash
    attr_reader :commits
    def commit; @commits = (@commits || 0) + 1; end
  end
  class Store < Hash
    def section(*args); @section ||= Section.new; end
  end
  class << self
    attr_accessor :held, :triggered
    def input_press?(key); (@held || []).include?(key); end
    def input_trigger?(key); (@triggered || []).include?(key); end
    def input_repeat?(key); input_trigger?(key); end
    def nvram; @nvram ||= Store.new; end
  end
end
module Input
  def self.trigger?(*args); true; end
  def self.press?(*args); true; end
  def self.repeat?(*args); true; end
  def self.dir4; 2; end
  def self.dir8; 2; end
end
module Graphics
  class << self; attr_accessor :frame_count; end
  self.frame_count = 0
  def self.width; 640; end
  def self.height; 480; end
end
module Sound
  def self.play_cursor; end
  def self.play_ok; end
  def self.play_cancel; end
  def self.play_buzzer; end
end
Color = Struct.new(:red, :green, :blue, :alpha)
Rect = Struct.new(:x, :y, :width, :height)
class Bitmap
  attr_reader :width, :height, :font, :clears
  def initialize(width, height)
    @width, @height = width, height
    @font = OpenStruct.new(:size => 24)
    @clears = 0
  end
  def fill_rect(*args); end
  def clear; @clears += 1; end
  def text_size(text); OpenStruct.new(:width => text.size * font.size / 2); end
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
class Sprite
  attr_accessor :bitmap, :x, :y, :z, :zoom_x, :zoom_y, :visible, :opacity
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
class Window_Base
  attr_accessor :x, :y, :z, :width, :height, :active, :index, :top_row
  attr_accessor :visible, :opacity, :openness, :back_opacity
  attr_reader :updates, :disposals
  def initialize(x, y, width, height)
    @x, @y, @width, @height, @z, @top_row = x, y, width, height, 0, 0
    @disposed, @updates, @disposals = false, 0, 0
    @visible, @opacity, @openness = true, 255, 255
  end
  def fitting_height(lines); 24 + lines * 24; end
  def line_height; 24; end
  def standard_padding; 12; end
  def contents; @contents ||= Bitmap.new(width - 24, height - 24); end
  def text_size(text); contents.text_size(text); end
  def change_color(*args); end
  def system_color; 0; end
  def normal_color; 0; end
  def draw_text(*args); end
  def reset_font_settings; contents.font.size = 24; end
  def update; @updates += 1; end
  def dispose; @disposed = true; @disposals += 1; end
  def disposed?; @disposed; end
  def activate; @active = true; end
  def deactivate; @active = false; end
  def open?; true; end
end
class Window_Command < Window_Base
  def initialize(x, y)
    @list = []
    make_command_list
    super(x, y, window_width, window_height)
    refresh
    select(0)
    activate
  end
  def window_width; 160; end
  def window_height; fitting_height(visible_line_number); end
  def visible_line_number; item_max; end
  def refresh; @list = []; make_command_list; end
  def make_command_list; end
  def add_command(name, symbol, enabled = true, ext = nil)
    @list << { :name => name, :symbol => symbol, :enabled => enabled, :ext => ext }
  end
  def item_max; @list.size; end
  def current_ext; @list[@index] && @list[@index][:ext]; end
  def current_symbol; @list[@index] && @list[@index][:symbol]; end
  def select(index); @index = index; end
  def select_symbol(symbol); select(@list.index { |x| x[:symbol] == symbol } || 0); end
  def command_enabled?(index); @list[index] && @list[index][:enabled]; end
  def cursor_movable?; active && item_max > 0; end
  def redraw_current_item; end
  def process_cursor_move; end
  def process_handling; end
  def process_ok; end
  def update; super; process_cursor_move; process_handling; end
end
class Scene_Base
  def update; update_basic; end
  def update_basic
    instance_variables.each do |name|
      value = instance_variable_get(name)
      value.update if value.is_a?(Window_Base) && !value.disposed?
    end
  end
  def terminate
    instance_variables.each do |name|
      value = instance_variable_get(name)
      value.dispose if value.is_a?(Window_Base) && !value.disposed?
    end
  end
end
module SceneManager
  class << self; attr_accessor :scene; end
  def self.run; end
end
load File.expand_path('../../mod_loader/framework/loader.rb', __dir__)
load File.expand_path('../../mod_loader/framework/input/capture.rb', __dir__)
load File.expand_path('../../mod_loader/framework/modmenu/bootstrap.rb', __dir__)

class TestChildWindow < ModMenu_CommandWindow
  attr_reader :confirmations
  def make_command_list
    add_command('First', :first)
    add_command('Second', :second)
  end
  def process_ok; @confirmations = (@confirmations || 0) + 1; end
end
