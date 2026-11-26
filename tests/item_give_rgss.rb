module ItemGiveTest
  def self.check(value, message)
    raise message unless value
    Map080Benchmark.log('PASS ' + message)
  end

  def self.run(scene)
    scene.toggle_give_window
    window = scene.instance_variable_get(:@executor_give_window)
    12.times { scene.update }
    header = window.instance_variable_get(:@switch_window)
    help = window.instance_variable_get(:@help_window)
    check(window.open? && header.open? && help.open?, 'constructor and opening animation')
    check(window.opacity == 0 && window.contents.width == 1 && window.contents.height == 1,
      'controller has no visible frame or full-size contents')
    check(header.contents.height >= header.line_height * 2, 'title and tabs both fit header bitmap')
    check(header.item_rect(0).y == header.line_height, 'cursor stays on tabs below title')
    [:item, :weapon, :armor, :item].each_with_index do |category, index|
      header.select(index % 3)
      window.update
      list = window.instance_variable_get(:@current_category_window)
      check(list.category == category && list.visible && list.open?, "switch #{category}")
      check(header.y + header.height < list.y && list.y + list.height < help.y,
        'panels are stacked without overlap')
      check(window.x >= 0 && window.y >= 0 && window.x + window.width <= Graphics.width &&
        window.y + window.height <= Graphics.height, 'panel group fits screen')
      window.on_category_ok
      check(list.active && !header.active, 'only list receives input after category confirm')
      list.select(list.item_max - 1)
      drawn = list.instance_variable_get(:@give_drawn_items).size
      check(drawn < list.item_max, 'first page and end page do not rasterize entire database')
      window.on_item_cancel
      check(header.active && !list.active, 'cancel returns focus to categories')
      saved_index = list.index
      window.on_category_ok
      check(list.index == saved_index, 'returning to list preserves selection')
      window.on_item_cancel
    end
    list = window.instance_variable_get(:@current_category_window)
    list.select(0)
    window.on_category_ok
    item = list.item
    before = $game_party.item_number(item)
    window.on_item_ok
    check($game_party.item_number(item) == before + 1 && list.active,
      'confirm gives exactly one item and retains list focus')
    $game_party.gain_item(item, -1)
    3.times { scene.update }
    check(ExecutorModule.give_text('executor.give.title') ==
      ModLoader::I18n['executor.give.title'], 'title uses selected I18n table')
    bitmap = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(bitmap, 'item-give.bmp')
    bitmap.dispose
    scene.toggle_give_window
    12.times { scene.update }
    check(window.close? && header.close? && help.close? && list.close?, 'all visible panels close together')
    check(!header.active && !list.active, 'closed panels cannot consume input')
    scene.toggle_give_window
    12.times { scene.update }
    check(window.open? && header.open? && help.open? && list.open?, 'all visible panels reopen together')
    children = window.instance_variable_get(:@category_windows).values + [header, help]
    window.dispose
    check(window.disposed? && children.all? { |child| child.disposed? }, 'controller releases every child')
    scene.instance_variable_set(:@executor_give_window, nil)
    scene.toggle_give_window
    12.times { scene.update }
    check(scene.instance_variable_get(:@executor_give_window).open?, 'new window after disposal')
  end
end
