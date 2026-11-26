module DisplayFilterIntegration
  def self.log(message)
    File.open('display-filter.log','ab') { |f| f.write(message.to_s+"\n") }
  end
  def self.run
    $display_filter_runs=($display_filter_runs || 0)+1
    scene=nil
    begin
      display=ModLoader::Display
      state=ModLoader.display_scaling_filter_status
      log "BOOT run=#{$display_filter_runs} #{state}"
      if $display_filter_runs>1
        raise 'F12 did not restore saved filter' unless state.include?('"filter":1')
      end
      DataManager.init;DataManager.setup_new_game
      $game_player.reserve_transfer(93,50,17,2);$game_player.perform_transfer
      SceneManager.goto(Scene_Map);scene=SceneManager.scene
      scene.start;scene.post_start
      display.parallel_rendering=false
      size=[Graphics.width,Graphics.height];render=ModLoader.hrfix_settings(true)
      raise 'Resize window failed' unless ModLoader.configure_display(0,977,733,0)
      10.times { scene.update }
      entry=ModLoader::ModMenu.items_for('Display').find { |e| e.label=='Scaling filter' }
      raise 'Filter menu unavailable' unless entry && entry.selectable?
      entry.value=:smooth
      raise 'Filter did not change' unless ModLoader.display_scaling_filter_status.include?('"filter":1')
      stored=ModLoader::NVRAMStore.new(File.join(ModLoader.data_directory,'nvram.dat'))
      raise 'Filter not saved to disk' unless stored.section(:display)[:scaling_filter]==:smooth
      before=ModLoader.display_scaling_filter_status
      24.times { scene.update }
      after=ModLoader.display_scaling_filter_status;log "SMOOTH #{after}"
      calls=proc { |s| s[/"gdi_calls":(\d+)/,1].to_i+s[/"ddraw_calls":(\d+)/,1].to_i }
      raise 'Filter not used by actual presentation' unless calls.call(after)>calls.call(before)
      raise 'Native scaling fell back' unless after.include?('"fallbacks":0')
      raise 'Filter changed internal resolution/config' unless size==[Graphics.width,Graphics.height] && render==ModLoader.hrfix_settings(true)
      if $display_filter_runs==1
        ModLoader.set_display_scaling_filter(0)
        raise RGSSReset
      end
      entry.value=:pixelated
      24.times { scene.update }
      raise 'Pixelated did not restore' unless ModLoader.display_scaling_filter_status.include?('"filter":0')
      raise 'Window geometry changed' unless size==[Graphics.width,Graphics.height]
      log "PIXELATED #{ModLoader.display_scaling_filter_status}"
      File.open('display-filter.result','wb') { |f| f.write('PASS') }
    rescue Exception => e
      raise if e.is_a?(RGSSReset)
      log "FAIL #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
      File.open('display-filter.result','wb') { |f| f.write('FAIL') }
    ensure
      scene.terminate if scene
      SceneManager.exit unless $display_filter_runs==1 && $!.is_a?(RGSSReset)
    end
  end
end
module SceneManager
  def self.run;DisplayFilterIntegration.run;end
end
