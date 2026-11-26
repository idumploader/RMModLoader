module LocalMap108Compare
  def self.run(scene)
    entries=ModLoader::ModMenu.items_for('Display')
    item=proc {|name| entries.find {|e| e.label==name} || raise('Missing menu option '+name)}
    settings=ModLoader::RendererSettings
    settings.parallel_rendering=false; settings.wait_for_frame=false
    settings.render_threads=1;settings.parallel_stretch=false;settings.direct_output=false
    threads=item.call('Render threads');stretch=item.call('Parallel viewport scaling');direct=item.call('Direct frame output')
    raise 'Threads unavailable' unless threads.selectable?
    raise 'OFF enabled live options' if stretch.selectable? || direct.selectable?
    item.call('Parallel rendering').value=true
    raise 'One thread enabled parallel scale' if stretch.selectable?
    threads.value=3;stretch.value=true;direct.value=true
    raise 'Values not applied' unless threads.value==3 && stretch.value && direct.value
    stored=ModLoader::NVRAMStore.new(File.join(ModLoader.data_directory,'nvram.dat')).section(:display)
    raise 'Values not written to disk' unless stored[:render_threads]==3 && stored[:parallel_stretch]==true && stored[:direct_output]==true
    ModLoader.parallel_renderer_set_workers(1);ModLoader.parallel_renderer_set_parallel_stretch(false);ModLoader.parallel_renderer_set_direct_output(false)
    raise 'Restore failed' unless settings.restore_renderer
    raise 'Saved values not restored' unless ModLoader.parallel_renderer_workers==3 && ModLoader.parallel_renderer_parallel_stretch && ModLoader.parallel_renderer_direct_output
    ModLoader.parallel_renderer_validation(true)
    ModLoader.parallel_renderer_frame_mode(0);ModLoader.parallel_renderer_frame_mode(3)
    48.times {scene.update}
    state=ModLoader.parallel_renderer_frame_status
    raise 'Pixel/output check failed '+state unless state.include?('"checks":6') && state.include?('"direct_checks":6') && state.include?('"error":""')
    Map080Benchmark.log('MENU_OPTIONS_PASS '+state)
    ModLoader::ModMenu.remember_position('Display',nil,0)
    scene.modmenu_update_hotkey
    menu=scene.instance_variable_get(:@modmenu_window)
    raise 'Display menu did not open' unless menu && menu.category=='Display'
    menu.select(entries.index(threads));menu.refresh_description
    Graphics.update
    shot=Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(shot,'renderer-menu-options.bmp');shot.dispose
    scene.modmenu_update_hotkey
    item.call('Parallel rendering').value=false
    state=ModLoader.parallel_renderer_frame_status
    raise 'OFF retained resources '+state unless state.include?('"memory_bytes":0') && state.include?('"worker_running":false')
    Map080Benchmark.log('MENU_OPTIONS_OFF_PASS '+state)
  ensure
    ModLoader.parallel_renderer_frame_mode(0)
  end
end
