module MenuRenderingResetTest
  def self.log(message)
    File.open('menu-rendering-reset.log','ab') { |f| f.write(message.to_s+"\n") }
  end
  def self.run
    $menu_rendering_reset_runs = ($menu_rendering_reset_runs || 0) + 1
    scene = nil
    begin
      control = ModLoader::MenuRendering
      if $menu_rendering_reset_runs > 1
        raise 'Fast blur preference lost' unless control.fast_blur?
        raise 'Transition preference lost' unless control.transition_mode == :fast
        raise 'Previous scene survived reset' unless control.previous_scene_class.nil?
      end
      DataManager.init; DataManager.setup_new_game
      $game_player.reserve_transfer(93,50,17,2); $game_player.perform_transfer
      SceneManager.goto(Scene_Map); scene = SceneManager.scene
      scene.start; scene.post_start
      16.times { scene.update }
      expected = Graphics.last_frame_to_bitmap; expected.blur
      control.fast_blur = true; control.transition_mode = :fast
      SceneManager.snapshot_for_background
      raise 'RGBA mismatch' unless ModLoader.parallel_renderer_pixels_equal(expected,SceneManager.background_bitmap)
      expected.dispose
      log "RUN #{$menu_rendering_reset_runs}: native blur/background pixels PASS, saved transitions=#{control.transition_mode}"
      if $menu_rendering_reset_runs == 1
        control.previous_scene_class = Scene_Menu
        raise RGSSReset
      end
      File.open('menu-rendering-reset.result','wb') { |f| f.write('PASS') }
    rescue Exception => error
      raise if error.is_a?(RGSSReset)
      log "FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}"
      File.open('menu-rendering-reset.result','wb') { |f| f.write('FAIL') }
    ensure
      SceneManager.exit unless $menu_rendering_reset_runs == 1
      scene.terminate if scene
    end
  end
end
module SceneManager
  def self.run; MenuRenderingResetTest.run; end
end
