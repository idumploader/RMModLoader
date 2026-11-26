module BSResolutionMenusTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.shot(label)
    3.times { Graphics.update }
    bitmap = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(bitmap, "resolution-#{label}.bmp")
    bitmap.dispose
  end
  def self.run(map_scene)
    title = Window_TitleCommand.new
    check(title.width == BSResolutionFix.pixels(160), 'title menu width')
    check(title.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'title menu font')
    check(title.x == (Graphics.width - title.width) / 2, 'title menu centred')
    check(title.y + title.height <= Graphics.height, 'title menu fits screen')
    title.dispose
    [Prico::Disp_SW1, Prico::Disp_SW2, Prico::Disp_SW3].each { |id| $game_switches[id] = true unless id == 0 }
    Window_MenuCommand.init_command_position
    actor = $game_party.members[0]
    actor.set_graphic(actor.character_name, actor.character_index, 'DS_Actor20', 0)
    $data_skills.compact.select { |skill| skill.id > 2 }.first(3).each { |skill| actor.learn_skill(skill.id) }
    SceneManager.snapshot_for_background
    map_scene.terminate
    map_scene.instance_variable_set(:@bsresolution_terminated, true)
    SceneManager.goto(Scene_Menu)
    scene = SceneManager.scene
    scene.start
    command = scene.instance_variable_get(:@command_window)
    status = scene.instance_variable_get(:@status_window)
    check(command.width >= BSResolutionFix.pixels(160), 'main menu command width')
    check(command.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'main menu font')
    check(status.width + command.width == Graphics.width, 'main menu columns fill screen')
    check(status.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'main menu actor font')
    location = scene.instance_variable_get(:@map_window)
    check(location.width == BSResolutionFix.pixels(200), 'location width')
    check(location.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'location font')
    check(location.x + location.width == Graphics.width && location.y + location.height == Graphics.height, 'location bottom right')
    bottom = scene.instance_variable_get(:@gold_window).y
    (1..3).each do |index|
      variable = scene.instance_variable_get("@Var_window#{index}")
      check(variable.width == command.width, "variable#{index} width")
      check(variable.contents.font.size == BSResolutionFix.pixels(Font.default_size), "variable#{index} font")
      check(variable.y + variable.height < bottom, "variable#{index} does not overlap")
      bottom = variable.y
    end
    check(bottom >= command.height, 'variable stack below menu commands')
    names = command.instance_variable_get(:@list).map { |entry| entry[:name] }
    check(names.all? { |name| command.text_size(name).width <= command.item_rect_for_text(0).width }, 'all menu labels fit without squeezing')
    check(scene.instance_variable_get(:@gold_window).width == command.width, 'gold follows menu column width')
    shot('menu')
    scene.terminate
    SceneManager.goto(Scene_Status)
    scene = SceneManager.scene
    scene.start
    status = scene.instance_variable_get(:@status_window)
    check(status.width == BSResolutionFix.pixels(440), 'Oxib status width')
    check(status.height == BSResolutionFix.pixels(480), 'Oxib status height')
    check(status.x == (Graphics.width - status.width) / 2, 'Oxib status centred')
    check(status.contents.is_a?(Bitmap), 'native contents returned outside drawing')
    check(status.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'Oxib native font size')
    3.times do |page|
      status.instance_variable_set(:@page, page)
      status.refresh
      check(status.contents.font.size == BSResolutionFix.pixels(Font.default_size), "status page#{page} font does not compound")
      shot("status-#{page}")
    end
    check(!Cache.face(actor.face_name).disposed?, 'status keeps cached face alive')
    scene.terminate
    SceneManager.goto(Scene_Equip)
    scene = SceneManager.scene
    scene.start
    equipment = scene.instance_variable_get(:@status_window)
    command = scene.instance_variable_get(:@command_window)
    slots = scene.instance_variable_get(:@slot_window)
    items = scene.instance_variable_get(:@item_window)
    check(equipment.width == BSResolutionFix.pixels(208), 'equipment parameter column width')
    check(equipment.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'equipment parameter font')
    check(command.x == equipment.width && slots.x == equipment.width, 'equipment columns aligned')
    check(items.y + items.height <= Graphics.height, 'equipment items fit screen')
    slots.select(0)
    slots.update_help
    check(slots.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'equipment slot font')
    equipment.set_temp_actor(Marshal.load(Marshal.dump(actor)))
    check(equipment.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'equipment comparison font')
    equipment.set_temp_actor(nil)
    shot('equip')
    scene.terminate
    # Supply headers in memory only. No user or stage save file is written.
    singleton = class << DataManager; self; end
    singleton.send(:alias_method, :bsresolution_test_header, :load_header)
    singleton.send(:define_method, :load_header) do |index|
      index == 1 ? nil : {:characters=>[[actor.character_name, actor.character_index]], :playtime_s=>'12:34:56'}
    end
    SceneManager.goto(Scene_Save)
    scene = SceneManager.scene
    scene.start
    windows = scene.instance_variable_get(:@savefile_windows)
    viewport = scene.instance_variable_get(:@savefile_viewport)
    check(scene.savefile_height == BSResolutionFix.pixels(64), 'save row size fits content')
    check(scene.visible_max == viewport.rect.height / scene.savefile_height, 'save visible row count')
    check(windows[0].contents.font.size == BSResolutionFix.pixels(Font.default_size), 'save font')
    3.times { windows[0].refresh }
    check(windows[0].contents.font.size == BSResolutionFix.pixels(Font.default_size), 'save refresh font does not compound')
    windows[0].selected = true
    check(windows[0].cursor_rect.y == (windows[0].contents.height - windows[0].line_height) / 2, 'save cursor vertically centred')
    scene.top_index = [scene.item_max - scene.visible_max, 0].max
    check(scene.bottom_index < scene.item_max, 'save last page in range')
    scene.top_index = 0
    shot('save')
    scene.terminate
    singleton.send(:alias_method, :load_header, :bsresolution_test_header)
    SceneManager.goto(Scene_Item)
    scene = SceneManager.scene
    scene.start
    categories = scene.instance_variable_get(:@category_window)
    items = scene.instance_variable_get(:@item_window)
    check(categories.contents.font.size == (Font.default_size * BSResolutionFix.category_scale).round, 'compact category font')
    check(categories.height < categories.fitting_height(1) + BSResolutionFix.pixels(24), 'compact category row height')
    check(items.y == categories.y + categories.height, 'items follow category row')
    shot('categories')
    scene.terminate
    SceneManager.goto(Scene_End)
    scene = SceneManager.scene
    scene.start
    ending = scene.instance_variable_get(:@command_window)
    ending.openness = 255
    check(ending.width == BSResolutionFix.pixels(160), 'exit menu width')
    check(ending.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'exit menu font')
    check(ending.x == (Graphics.width - ending.width) / 2 && ending.y == (Graphics.height - ending.height) / 2, 'exit menu centred')
    shot('exit')
    scene.terminate
    BattleManager.setup(1, true, false)
    state_data = $data_states.compact.find { |state| state.id > 1 && state.icon_index > 0 }
    actor.add_state(state_data.id)
    actor.add_buff(0, 3)
    $game_troop.members.first.add_buff(1, 2)
    SceneManager.goto(Scene_Battle)
    scene = SceneManager.scene
    scene.start
    scene.command_state
    states = scene.instance_variable_get(:@state_window)
    help = scene.instance_variable_get(:@help_window)
    states.openness = 255
    check(states.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'battle effects font')
    check(states.item_width == BSResolutionFix.pixels(24) + BSResolutionFix.pixels(2), 'battle effects icon cells')
    check(states.width == BSResolutionFix.pixels(144) + states.col_max * states.item_width + states.standard_padding * 2, 'battle effects width')
    check(states.y >= help.height && states.y + states.height <= Graphics.height, 'battle effects below help and in screen')
    check(states.item_rect(0).x == BSResolutionFix.pixels(143), 'battle effects cursor aligned')
    check(states.index >= 0 && !states.description.empty?, 'battle effects description navigation')
    3.times { states.refresh }
    check(states.contents.font.size == BSResolutionFix.pixels(Font.default_size), 'battle effects turn font restored')
    states.update_help
    shot('effects')
    scene.command_state_cancel
    check(scene.instance_variable_get(:@actor_command_window).active, 'battle effects cancel returns to commands')
    scene.terminate
    map_name = Window_MapName.new
    check(map_name.contents.font.size == (Font.default_size * BSResolutionFix.category_scale).round, 'map banner font')
    check(map_name.height == map_name.fitting_height(1), 'map banner height')
    map_name.contents_opacity = 255
    item = $data_items.compact.find { |entry| entry.id > 0 }
    before = $game_party.item_number(item)
    notice = Window_Getinfo.new(item.id, 0, 'Item received', 1)
    check($game_party.item_number(item) == before + 1, 'notification grants item exactly once')
    check(notice.width == (672 * BSResolutionFix.category_scale).round, 'notification width')
    check(notice.height == (70 * BSResolutionFix.category_scale).round, 'notification height')
    check(notice.contents.font.size == (14 * BSResolutionFix.category_scale).round, 'notification small caption font')
    original_name = item.name
    item.name = 'A very long item name which previously collided with quantity'
    before_long = $game_party.item_number(item)
    long_notice = Window_Getinfo.new(item.id, 0, 'Long item received', 2)
    check($game_party.item_number(item) == before_long + 2, 'long notification grants exactly once')
    columns = long_notice.instance_variable_get(:@bsresolution_getinfo_columns)
    check(columns[0] < columns[1] && columns[2] < columns[3], 'long item name quantity description separated')
    check(item.name == 'A very long item name which previously collided with quantity', 'display truncation does not mutate item')
    item.name = original_name
    long_notice.update
    long_notice.contents_opacity = 255
    another = Window_Getinfo.new('Notification', 5, 'Caption', 0)
    check(another.y < notice.y, 'notification stack spacing')
    notice.update
    another.update
    check(notice.viewport.nil?, 'notification remains outside scaled map viewport')
    notice.contents_opacity = 255
    another.contents_opacity = 255
    shot('notifications')
    slot = notice.instance_variable_get(:@i)
    notice.dispose
    check($game_temp.getinfo_size[slot].nil?, 'notification slot released')
    another.dispose
    long_notice.dispose
    map_name.dispose
    Map080Benchmark.log('BSResolutionMenusTest PASS')
  ensure
    singleton.send(:alias_method, :load_header, :bsresolution_test_header) if singleton && DataManager.respond_to?(:bsresolution_test_header)
  end
end
