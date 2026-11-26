module RenderSnapshotDisplayReset
  def self.log(message)
    File.open('display-f12.log','ab') { |f| f.write(message.to_s+"\n") }
  end
  def self.run
    ModLoader.parallel_renderer_validation(true)
    $display_reset_runs=($display_reset_runs || 0)+1
    scene=nil
    begin
      if $display_reset_runs>1
        state=ModLoader.parallel_renderer_frame_status
        log "AFTER_RESET #{state}"
        raise 'Display did not restore parallel mode' unless state.include?('"mode":3')
        raise 'Old worker survived F12' unless
          ModLoader.parallel_renderer_status.include?('"queue_depth":0')
      end
      DataManager.init
      DataManager.setup_new_game
      $game_player.reserve_transfer(93,50,17,2)
      $game_player.perform_transfer
      SceneManager.goto(Scene_Map)
      scene=SceneManager.scene
      scene.start; scene.post_start
      if $display_reset_runs==1
        ModLoader::Display.parallel_rendering=false
        ModLoader::Display.wait_for_frame=false
        ModLoader::Display.parallel_rendering=true
        raise 'Could not enable parallel mode' unless ModLoader::Display.renderer_mode==3
        35.times { scene.update }
        log "BEFORE_RESET #{ModLoader.parallel_renderer_frame_status}"
        raise 'No worker frames before reset' unless
          ModLoader.parallel_renderer_frame_status[/"submits":(\d+)/,1].to_i>0
        raise RGSSReset
      end
      40.times { scene.update }
      state=ModLoader.parallel_renderer_frame_status
      log "RECOVERED #{state}"
      raise 'Parallel mode failed after reset' unless state.include?('"mode":3') &&
        state.include?('"checks":6') && state.include?('"error":""')
      ModLoader::Display.parallel_rendering=false
      File.open('display-f12.result','wb') { |f| f.write('PASS') }
    rescue Exception => e
      raise if e.is_a?(RGSSReset)
      log "FAIL #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
      File.open('display-f12.result','wb') { |f| f.write('FAIL') }
    ensure
      SceneManager.exit unless $display_reset_runs==1
      scene.terminate if scene
    end
  end
end
module SceneManager
  def self.run; RenderSnapshotDisplayReset.run; end
end
