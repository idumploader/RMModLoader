module RenderSnapshotLifecycle
  def self.run(scene)
    probe=ModLoader::ParallelRenderer
    begin
      Window_MenuCommand.init_command_position
      probe.optimization(2)
      raise probe.status unless ModLoader.parallel_renderer_frame_mode(3)
      60.times { scene.update }
      3.times do |cycle|
        [Scene_Menu, Scene_Item, Scene_Map].each do |klass|
          SceneManager.snapshot_for_background if klass==Scene_Menu
          scene.pre_terminate
          scene.terminate
          SceneManager.goto(klass)
          scene=SceneManager.scene
          scene.start
          scene.post_start
          120.times { scene.update }
          state=ModLoader.parallel_renderer_frame_status
          raise state unless state.include?('"mode":3') && state.include?('"error":""')
          puts "LIFECYCLE #{cycle} #{klass} PASS #{state}"
        end
      end
      scene
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      probe.clear
    end
  end
end
