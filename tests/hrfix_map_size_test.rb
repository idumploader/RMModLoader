require 'minitest/autorun'
require 'ostruct'
require 'open3'
require 'rbconfig'
require_relative 'support/hrfix_map_rgss'
load File.expand_path('../mod_loader/framework/renderer/hrfix_map_size.rb', __dir__)

class HRFixMapSizeTest < Minitest::Test
  def setup
    HRFix::MapSize.instance_variable_set(:@original, true)
    $game_map = Game_Map.new
    $game_player = Game_Player.new
    $game_player.x, $game_player.y = 50, 40
  end

  def test_camera_and_edges_use_original_view_without_changing_graphics
    assert_equal [20, 15], [$game_map.screen_tile_x, $game_map.screen_tile_y]
    $game_player.center(50, 40)
    assert_equal [40.5, 33.0], [$game_map.display_x, $game_map.display_y]
    $game_map.scroll_right(1000)
    $game_map.scroll_down(1000)
    assert_equal [80, 65], [$game_map.display_x, $game_map.display_y]
    assert_equal [1280, 960], [Graphics.width, Graphics.height]
  end

  def test_small_maps_and_loop_seam
    small = Game_Map.new(10, 8)
    small.set_display_pos(100, 100)
    assert_equal [0, 0], [small.display_x, small.display_y]
    $game_map.loop_x = $game_map.loop_y = true
    $game_map.set_display_pos(98, 79)
    assert_equal 3, $game_map.adjust_x(1)
    $game_map.scroll_right(4)
    $game_map.scroll_down(3)
    assert_equal [2, 2], [$game_map.display_x, $game_map.display_y]
  end

  def test_map_capture_excludes_picture_and_ui_viewports_and_is_released
    sprites = Spriteset_Map.new
    sprites.create_viewports
    assert_equal [640, 480], sprites.viewport1.source
    assert_nil sprites.viewport2.source
    assert_nil sprites.viewport3.source
    sprites.dispose_viewports
    assert_equal [0, 0], sprites.viewport1.source
    assert sprites.viewport1.disposed
  end

  def test_parallax_and_weather_stay_in_logical_map_coordinates
    $game_map.set_display_pos(20, 10)
    assert_equal 60, $game_map.parallax_ox(OpenStruct.new(:width => 1120))
    assert_equal 40, $game_map.parallax_oy(OpenStruct.new(:height => 1000))
    sprites = Spriteset_Map.new
    sprites.create_weather
    particle = OpenStruct.new
    50.times do
      sprites.weather.create_new_particle(particle)
      assert (-100...640).include?(particle.x)
      assert (-200...480).include?(particle.y)
    end
    normal_weather = Spriteset_Weather.new
    normal_weather.create_new_particle(particle)
    assert_equal 1, normal_weather.original_calls
  end

  def test_saved_camera_is_recentred_after_loading
    $game_map.set_display_pos(10, 5)
    system = Game_System.new
    system.on_after_load
    assert system.loaded
    assert_equal [40.5, 33.0], [$game_map.display_x, $game_map.display_y]
  end

  def test_runtime_map_size_switch_changes_camera_parallax_and_new_viewports
    HRFix::MapSize.instance_variable_set(:@original, false)
    assert_equal [40, 30], [$game_map.screen_tile_x, $game_map.screen_tile_y]
    assert_equal [19.5, 14.5], [$game_player.center_x, $game_player.center_y]
    assert_equal 123, $game_map.parallax_ox(OpenStruct.new(:width => 1120))
    sprites = Spriteset_Map.new
    sprites.create_viewports
    assert_nil sprites.viewport1.source
    sprites.create_weather
    refute sprites.weather.hrfix_original_map_size
    HRFix::MapSize.instance_variable_set(:@original, true)
    sprites = Spriteset_Map.new
    sprites.create_viewports
    assert_equal [640, 480], sprites.viewport1.source
    sprites.create_weather
    assert sprites.weather.hrfix_original_map_size
  end

  def test_default_render_mode_does_not_install_map_overrides
    fixture = File.expand_path('support/hrfix_map_rgss.rb', __dir__)
    script = File.expand_path('../mod_loader/framework/renderer/hrfix_map_size.rb', __dir__)
    code = "load ARGV[0]; load ARGV[1]; m = Game_Map.new; s = Spriteset_Map.new; s.create_viewports; abort unless [m.screen_tile_x, m.screen_tile_y] == [40, 30] && s.viewport1.source.nil?"
    out, status = Open3.capture2e({'HRFIX_TEST_MAP' => 'render'}, RbConfig.ruby, '-e', code, fixture, script)
    assert status.success?, out
  end
end
