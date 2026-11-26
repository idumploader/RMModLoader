module BSResolutionBattleTest
  def self.check(value, message)
    BSResolutionTest.check(value, message)
  end
  def self.shot(name)
    3.times { Graphics.update }
    # Compare every native RGBA pixel, including scaled enemies and status UI,
    # against the existing compositor before advancing any game animation.
    if Graphics.width == 1400
    probe = ModLoader::ParallelRenderer
    expected, actual, blank = Array.new(3) { Bitmap.new(Graphics.width, Graphics.height) }
    begin
      probe.reference_frame(expected)
      probe.capture_frame
      probe.submit_frame(blank)
      probe.collect(actual)
      check(ModLoader.parallel_renderer_pixels_equal(expected, actual), "worker RGBA #{name}")
    ensure
      probe.clear
      [expected, actual, blank].each { |image| image.dispose }
    end
    end
    bitmap = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(bitmap, name)
    bitmap.dispose
  end
  def self.run(map_scene)
    scale = BSResolutionFix.scale
    help = Window_Help.new
    options = Window_SystemOptions.new(help)
    options.select(0)
    check(options.line_height == BSResolutionFix.pixels(24), 'options row height')
    check(options.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'options font')
    shot('resolution-options.bmp')
    options.dispose; help.dispose
    # A normal Scene_Battle.start, with the map scene disposed first.
    map_scene.terminate
    map_scene.instance_variable_set(:@bsresolution_terminated, true)
    BattleManager.setup(1, true, false)
    SceneManager.goto(Scene_Battle)
    battle = SceneManager.scene
    battle.start
    battle.instance_variable_get(:@spriteset).update
    status = battle.instance_variable_get(:@status_window)
    status.openness = 255
    status.refresh
    info = battle.instance_variable_get(:@info_viewport)
    check(info.rect.y + info.rect.height == Graphics.height, 'battle status bottom anchor')
    check(status.line_height == BSResolutionFix.pixels(24), 'battle status row height')
    actor_command = battle.instance_variable_get(:@actor_command_window)
    actor = $game_party.battle_members[0]
    actor.instance_variable_set(:@name, 'Тест')
    actor_command.setup(actor)
    actor_command.openness = 255
    check(actor_command.width == BSResolutionFix.pixels(256), 'battle action width')
    check(actor_command.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'battle action font')
    check(actor_command.y >= 0 && actor_command.y + actor_command.height <= Graphics.height, 'battle action fits screen')
    enemies = battle.instance_variable_get(:@spriteset).instance_variable_get(:@enemy_sprites)
    Map080Benchmark.log("ENEMIES #{enemies.map { |sprite| [sprite.battler.enemy.id, sprite.zoom_x, sprite.zoom_y, sprite.instance_variable_get(:@use_tmbsprex)] }.inspect}")
    baseline = enemies.map { |sprite| sprite.zoom_x }
    20.times { battle.instance_variable_get(:@spriteset).update }
    check(enemies.map { |sprite| sprite.zoom_x } == baseline, 'enemy scale does not accumulate')
    check(enemies.all? { |sprite| sprite.instance_variable_get(:@bsresolution_enemy_scale) == scale }, 'enemy resolution scale applied')
    enemies.each { |sprite| sprite.opacity = 255 }
    shot('resolution-battle.bmp')
    skills = battle.instance_variable_get(:@skill_window)
    sample = $data_skills.compact.find { |skill| skill.id > 2 && !skill.name.empty? }
    learned = $data_skills.compact.select { |skill| skill.stype_id == sample.stype_id && !skill.name.empty? }.first(6)
    learned.each { |skill| actor.learn_skill(skill.id) }
    skills.actor = actor
    skills.stype_id = sample.stype_id
    skills.refresh
    skills.show
    skills.activate
    skills.select(0)
    skills.openness = 255
    Map080Benchmark.log("SKILLS items=#{skills.item_max} visible=#{skills.visible} open=#{skills.openness} contents_opacity=#{skills.contents_opacity} font=#{skills.contents.font.size} methods=#{skills.method(:draw_item).source_location.inspect} data=#{skills.instance_variable_get(:@data).map { |skill| skill && skill.name }.inspect}")
    check(skills.line_height == BSResolutionFix.pixels(24), 'battle skill row height')
    check(skills.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'battle skill font')
    check(skills.y + skills.height <= info.rect.y, 'skills fit above status')
    shot('resolution-skills.bmp')
    skills.hide
    actor_command.setup(actor)
    party = battle.instance_variable_get(:@party_command_window)
    party.clear_command_list
    party.make_command_list
    party.refresh
    party.openness = 255
    check(party.width <= Graphics.width && party.height <= Graphics.height, 'party command fits screen')
    battle.terminate
  ensure
    options.dispose if options && !options.disposed?
    help.dispose if help && !help.disposed?
  end
end
