module RenderSnapshotDisplay
  def self.run(scene)
    menu=effect=nil
    begin
      entries=ModLoader::ModMenu.items_for('Display')
      parallel=entries.find { |e| e.label=='Parallel rendering' }
      wait=entries.find { |e| e.label=='Wait for new frame' }
      limit=entries.find { |e| e.label=='Renderer memory limit' }
      raise 'Renderer controls unavailable' unless parallel && wait && parallel.selectable?
      raise 'Snapshot limit control unavailable' unless limit && limit.selectable?
      raise 'Unexpected default snapshot limit' unless limit.value==256
      ModLoader::Display.settings[:wait_for_frame]=false
      ModLoader::ModMenu.remember_position('Display',nil,0)
      scene.modmenu_update_hotkey
      menu=scene.instance_variable_get(:@modmenu_window)
      raise 'Display category did not open' unless menu.category=='Display'
      menu.select(entries.index(limit))
      limit.on_right(menu)
      menu.apply_change
      raise 'Snapshot limit did not change through Display' unless
        ModLoader.parallel_renderer_memory_limit_mib==272
      ModLoader::ParallelRenderer.pixel_limit_mib=192
      raise 'Display did not follow Ruby limit' unless limit.value==192
      raise 'Ruby limit was not saved' unless ModLoader::Display.settings[:memory_limit_mib]==192
      stored=ModLoader::NVRAMStore.new(File.join(ModLoader.data_directory,'nvram.dat'))
      raise 'Ruby limit was not written to NVRAM' unless
        stored.section(:display)[:memory_limit_mib]==192
      raise 'Native limit reset failed' unless ModLoader.parallel_renderer_set_memory_limit_mib(128)
      raise 'Saved limit did not restore' unless ModLoader::Display.restore_memory_limit && limit.value==192
      limit.value=256
      raise 'Snapshot limit did not reset' unless ModLoader.parallel_renderer_memory_limit_mib==256
      menu.select(entries.index(parallel))
      parallel.on_ok(menu)
      menu.apply_change
      raise 'Nonblocking mode not selected' unless ModLoader::Display.renderer_mode==3
      [3,2].each do |mode|
        if mode==2
          menu=scene.instance_variable_get(:@modmenu_window)
          menu.select(entries.index(wait))
          wait.on_ok(menu)
          menu.apply_change
        end
        3.times do |cycle|
          scene.modmenu_update_hotkey
          20.times { scene.update }
          puts "DISPLAY_CLOSE mode=#{mode} cycle=#{cycle} #{ModLoader.parallel_renderer_frame_status}"
          raise 'Renderer disabled on F10 close' unless ModLoader::Display.renderer_mode==mode
          scene.modmenu_update_hotkey
          20.times { scene.update }
          puts "DISPLAY_OPEN mode=#{mode} cycle=#{cycle} #{ModLoader.parallel_renderer_frame_status}"
          raise 'Renderer disabled on F10 open' unless ModLoader::Display.renderer_mode==mode
        end
        effect=Viewport.new(0,0,32,32)
        effect.zoom=1.5
        4.times { scene.update }
        puts "DISPLAY_EFFECT mode=#{mode} #{ModLoader.parallel_renderer_frame_status}"
        raise 'Effect permanently disabled renderer' unless ModLoader::Display.renderer_mode==mode
        effect.zoom=1.0
        20.times { scene.update }
        raise 'Renderer did not resume after effect' unless ModLoader::Display.renderer_mode==mode && ModLoader.parallel_renderer_frame_status.include?('"error":""')
        effect.dispose
        effect=nil
      end
      menu=scene.instance_variable_get(:@modmenu_window)
      menu.refresh
      menu.select(entries.index(parallel))
      menu.refresh_description
      Graphics.update
      shot=Graphics.snap_to_bitmap
      ModLoader.dump_as_bmp(shot,'display-renderer.bmp'); shot.dispose
      wait.value=true
      raise 'Waiting mode not selected' unless ModLoader::Display.renderer_mode==2
      20.times { scene.update; menu.update }
      wait.value=false
      raise 'Nonblocking mode not restored' unless ModLoader::Display.renderer_mode==3
      20.times { scene.update; menu.update }
      puts "DISPLAY_RENDERER active PASS #{ModLoader.parallel_renderer_frame_status}"
      parallel.value=false
      raise 'Original mode not restored' unless ModLoader::Display.renderer_mode==0
      raise 'Wait control still enabled' if wait.selectable?
      puts 'DISPLAY_RENDERER toggle original/nonblocking/wait/nonblocking/original PASS'
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      effect.dispose if effect && !effect.disposed?
      scene.modmenu_dispose_window
      ModLoader::ModMenu.on_close
    end
  end
end
