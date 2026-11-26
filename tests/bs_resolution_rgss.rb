module BSResolutionTest
  def self.check(value, message)
    raise message unless value
    Map080Benchmark.log("PASS #{message}")
  end
  def self.run(scene)
    scale = BSResolutionFix.scale
    check(Prico::WindowY1 == Graphics.height - 110, 'Prico bottom anchor')
    check(Prico::WindowY3 == Graphics.height - 230, 'Prico upper anchor')
    hud = scene.instance_variable_get(:@kiseki_status_window)
    check(hud.item_width == (70 * scale).round, 'HUD scaled item width')
    hud.visible = true
    hud.refresh
    face = Cache.face($game_party.battle_members[0].face_name)
    check(!face.disposed?, 'cached face remains valid')
    cached_frame = nil
    hud.bsresolution_artwork('Actor_bg2') do |bitmap|
      cached_frame = bitmap
      check(bitmap.width == BSResolutionFix.pixels(Cache.system('Actor_bg2').width), 'frame final width')
    end
    hud.bsresolution_artwork('Actor_bg2') { |bitmap| check(cached_frame.equal?(bitmap), 'decorative frame reused') }
    probe = Window_KisekiStatus.new
    probe.dispose
    check(!cached_frame.disposed?, 'shared decorative frame survives window disposal')
    check(!face.disposed?, 'window disposal keeps cached face valid')
    actor = $game_party.battle_members[0]
    actor.set_graphic(actor.character_name, actor.character_index, 'DS_Actor20', 0)
    hud.refresh
    hud.visible = true
    hud.openness = 255
    3.times { Graphics.update }
    Map080Benchmark.log("HUD visible=#{hud.visible} open=#{hud.openness} pos=#{hud.x},#{hud.y} contents=#{hud.contents.width}x#{hud.contents.height}")
    shot = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(shot, 'resolution-hud.bmp')
    shot.dispose
    fog = scene.instance_variable_get(:@spriteset)
    $game_map.bmsp_fog[:file] = 'kurayami01'
    fog.bmsp_mapfog_update_fog
    plane = fog.instance_variable_get(:@bmsp_fog)
    check((plane.bitmap.width * plane.zoom_x - Graphics.width).abs < 0.01, 'darkness covers width once')
    check((plane.bitmap.height * plane.zoom_y - Graphics.height).abs < 0.01, 'darkness covers height once')
    $game_map.bmsp_fog[:file] = ''
    fog.bmsp_mapfog_update_fog
    check(plane.zoom_x == 1.0 && plane.zoom_y == 1.0, 'ordinary fog scale restored')
    help = Window_Help.new
    list = Window_ItemList.new(0, help.height, Graphics.width, Graphics.height - help.height)
    list.help_window = help
    $data_items.compact.select { |item| item.itype_id == 1 && !item.name.empty? }.first(6).each do |item|
      $game_party.gain_item(item, 2)
    end
    list.category = :item
    list.refresh
    check(list.line_height == (24 * scale).round, 'item row height')
    Map080Benchmark.log("FONT actual=#{list.contents.font.size} default=#{Font.default_size} source=#{list.method(:reset_font_settings).source_location.inspect}")
    check(list.contents.font.size == (Font.default_size * scale).round, 'item font size')
    list.select(0)
    help.set_text('Предметы: проверка размеров текста и иконок')
    check(help.contents.font.size == (Font.default_size * scale).round, 'help font size')
    Graphics.update
    shot = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(shot, 'resolution-items.bmp')
    shot.dispose
    list.dispose
    help.dispose
    message = Window_Message.new
    $game_message.position = 2
    message.update_placement
    message.openness = 255
    message.reset_font_settings
    actor = $game_party.battle_members[0]
    message.draw_face(actor.face_name, actor.face_index, 0, 0)
    message.draw_text(message.new_line_x + BSResolutionFix.pixels(112), 0,
      message.contents_width - BSResolutionFix.pixels(112), message.line_height, 'Диалог при новом разрешении')
    check(message.y + message.height == Graphics.height, 'message touches bottom edge')
    check(message.contents_height >= BSResolutionFix.pixels(96), 'message face fits')
    $game_message.choices.replace(['Первый вариант', 'Второй вариант', 'Отмена'])
    choice = message.instance_variable_get(:@choice_window)
    choice.start
    choice.openness = 255
    Graphics.update
    check(choice.y + choice.height <= message.y, 'choices above message')
    check(choice.width <= Graphics.width, 'choices fit screen')
    shot = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(shot, 'resolution-dialog.bmp')
    shot.dispose
    message.dispose
    $game_message.clear
    eval(File.read('D:/workdir/codex/bsmp/RMModLoader/tests/bs_resolution_battle_rgss.rb'))
    BSResolutionBattleTest.run(scene)
    Map080Benchmark.log('BSResolutionTest PASS')
  ensure
    list.dispose if list && !list.disposed?
    help.dispose if help && !help.disposed?
    message.dispose if message && !message.disposed?
  end
end
