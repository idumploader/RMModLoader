require_relative 'support/modmenu_rgss'

class Viewport
  attr_accessor :z
  def initialize(*args); end
  def dispose; @disposed = true; end
  def disposed?; !!@disposed; end
end
class Sprite
  def initialize(*args); end
end
class Bitmap
  attr_reader :draws
  def draw_text(*args); @draws = (@draws || 0) + 1; end
end
module Graphics
  def self.update; :original; end
end
module ModLoader
  # Real loader defines these namespaces; notification objects must use ::.
  module Viewport; end
  module Bitmap; end
  module Display
    class << self; attr_accessor :enabled; end
    def self.renderer_notices?; !!enabled; end
  end
  class << self
    attr_accessor :health_calls, :health
    def parallel_renderer_health
      self.health_calls += 1
      health
    end
  end
end
load File.expand_path('../mod_loader/framework/renderer/parallel_renderer.rb', __dir__)

class RendererNoticeTest < Minitest::Test
  def setup
    ModLoader::RendererNotice.clear
    ModLoader.health_calls = 0
    ModLoader.health = 0
    ModLoader::Display.enabled = false
  end

  def teardown; ModLoader::RendererNotice.clear; end

  def test_disabled_never_polls_and_enabled_polls_once_per_sixty_updates
    assert_equal :original, Graphics.update
    119.times { Graphics.update }
    assert_equal 0, ModLoader.health_calls
    ModLoader::Display.enabled = true
    120.times { Graphics.update }
    assert_equal 2, ModLoader.health_calls
    assert_nil ModLoader::RendererNotice.instance_variable_get(:@sprite)
  end

  def test_unchanged_warning_reuses_bitmap_and_recovery_disposes_it
    ModLoader::Display.enabled = true
    ModLoader.health = 3
    Graphics.update
    sprite = ModLoader::RendererNotice.instance_variable_get(:@sprite)
    bitmap = sprite.bitmap
    120.times { Graphics.update }
    assert_same sprite, ModLoader::RendererNotice.instance_variable_get(:@sprite)
    assert_equal 1, bitmap.draws
    ModLoader.health = 0
    60.times { Graphics.update }
    assert_nil ModLoader::RendererNotice.instance_variable_get(:@sprite)
    assert sprite.disposed?
    assert bitmap.disposed?
  end
end
