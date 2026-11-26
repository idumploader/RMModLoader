module BSDialogNameTest
  def self.check(value, label)
    raise label unless value
    Map080Benchmark.log("PASS #{label}")
  end
  def self.run(scene)
    name = "\u0420\u043e\u0441\u0443\u043c\u0435\u043a\u043e"
    expected_size = ModLoader.hrfix_enabled ? (20 * [[Graphics.width / 640.0, Graphics.height / 480.0].min, 1.0].max).round : 20
    cached = Cache.name_bitmap(name)
    check(cached.font.size == expected_size, "font size #{expected_size}")
    check(cached.width > cached.text_size(name).width, 'name has horizontal margins')
    check(cached.height > expected_size, 'name has vertical margins')
    a = Window_FaceName.new(name, 300)
    b = Window_FaceName.new(name, 310)
    first = a.instance_variable_get(:@name_sprite)
    second = b.instance_variable_get(:@name_sprite)
    check(first.bitmap != second.bitmap && first.bitmap != cached, 'windows own independent name bitmaps')
    a.dispose
    check(!second.bitmap.disposed? && !cached.disposed?, 'disposing one label keeps other label and cache alive')
    previous = second
    previous_bitmap = second.bitmap
    b.setup_name_window(name + ' II')
    check(previous.disposed? && previous_bitmap.disposed?, 'changing name releases previous sprite and bitmap')
    check(b.width > b.instance_variable_get(:@name_sprite).bitmap.width, 'frame fits resized name')
    check(b.height > b.instance_variable_get(:@name_sprite).bitmap.height, 'frame fits name height')
    b.dispose
    message = Window_Message.new
    $game_system.use_name_window = true
    $game_temp.direct_show_name = name
    message.openness = 255
    message.draw_face("\u841d\u65af\u6885\u53ef (2)", 0, 0, 0)
    label = message.instance_variable_get(:@name_windows)[name]
    check(label && label.visible, 'dialog creates name label')
    check(label.instance_variable_get(:@name_sprite).bitmap.font.size == expected_size, 'dialog name uses scaled font')
    check($game_temp.direct_show_name.empty?, 'one-shot speaker name is consumed once')
    label.update
    [0, 1, 2].each do |position|
      $game_message.position = position
      message.update_placement
      $game_temp.direct_show_name = name
      message.show_name_window('', 0, 0, 96)
      check(label.y + label.height <= message.y + message.padding ||
        label.y >= message.y + message.height - message.padding,
        "position#{position}: name frame avoids dialogue contents")
      check(label.y < message.y + message.height && label.y + label.height > message.y,
        "position#{position}: name frame attached to dialogue border")
      check(label.y >= 0 && label.y + label.height <= Graphics.height,
        "position#{position}: name frame on screen")
      label.update
      check(label.instance_variable_get(:@name_sprite).y == label.y + label.height / 2,
        "position#{position}: sprite follows frame")
    end
    message.contents.draw_text(180, 0, 350, message.line_height, 'Dialogue text')
    3.times { Graphics.update }
    shot = Graphics.snap_to_bitmap
    ModLoader.dump_as_bmp(shot, 'dialog-name.bmp')
    shot.dispose
    message.dispose
    check(!Cache.name_bitmap(name).disposed?, 'dialog disposal keeps cached name reusable')
    Map080Benchmark.log('DIALOG NAME COMPLETE')
  end
end
