module BSHudCacheResetTest
  def self.log(message)
    File.open('map080.log','ab') { |f| f.write(message.to_s+"\n") }
  end
  def self.run
    $hud_cache_reset_runs=($hud_cache_reset_runs || 0)+1
    scene=nil
    begin
      raise 'Cache survived scene restart' unless BSHudBitmapCache.status[:bytes]==0
      raise 'Previous derived bitmap not disposed' if $hud_cache_reset_bitmap && !$hud_cache_reset_bitmap.disposed?
      DataManager.init; DataManager.setup_new_game
      $game_player.reserve_transfer(80,55,38,2); $game_player.perform_transfer
      SceneManager.goto(Scene_Map); scene=SceneManager.scene
      scene.start; scene.post_start
      actor=$game_party.battle_members[0]
      BSHudBitmapCache.portrait(actor.face_name,actor.face_index,BSResolutionFix.pixels(48)) { |b| $hud_cache_reset_bitmap=b }
      raise 'Empty derived cache' unless BSHudBitmapCache.status[:bytes]>0
      log "PASS reset run#{$hud_cache_reset_runs}: #{BSHudBitmapCache.status.inspect}"
      raise RGSSReset if $hud_cache_reset_runs==1
      File.open('map080.result','wb') { |f| f.write('PASS') }
    rescue Exception => error
      raise if error.is_a?(RGSSReset)
      log "FAIL #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}"
      File.open('map080.result','wb') { |f| f.write('FAIL') }
    ensure
      scene.terminate if scene
      SceneManager.exit unless $hud_cache_reset_runs==1
    end
  end
end
module SceneManager
  def self.run; BSHudCacheResetTest.run; end
end
