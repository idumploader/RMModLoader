require_relative 'support/modmenu_rgss'

class ModMenuWindowsTest < Minitest::Test
  M = ModLoader::ModMenu
  K = ModLoader::Keyboard
  def setup
    ModLoader.held = ModLoader.triggered = []
    M.on_close
    M.section.delete(:navigation)
    M.instance_variable_set(:@release_guard, false)
    M.instance_variable_set(:@items, {})
    M.instance_variable_set(:@categories, [])
    ModLoader::InputCapture.reset
    M.window('Root child', :category => 'Co-op') { TestChildWindow.new }
    @scene = Scene_Base.new
    SceneManager.scene = @scene
  end
  def teardown
    @scene.terminate
    M.on_close
  end
  def tick(*keys)
    ModLoader.held = ModLoader.triggered = keys
    Graphics.frame_count += 1
    @scene.update
  end
  def root; @scene.instance_variable_get(:@modmenu_window); end
  def open_root
    tick(K::F10)
    tick
    root
  end
  def test_root_close_key_is_captured_until_released
    open_root
    tick(K::ESC)
    assert_nil root
    refute M.active?
    refute Input.trigger?(:B)
    tick(K::ESC)
    refute Input.press?(:B)
    tick
    assert Input.press?(:B)
  end
  def test_child_cannot_own_itself_or_its_ancestor
    menu = open_root
    assert_raises(ArgumentError) { menu.open_child(menu) }
    child = TestChildWindow.new
    menu.open_child(child)
    assert_raises(ArgumentError) { child.open_child(menu) }
    assert_same child, menu.child_window
    assert_nil child.child_window
  end
  def test_generic_window_factory_and_existing_actions
    M.window('Child', :category => 'Co-op') { TestChildWindow.new }
    called = 0
    M.action('Action', :category => 'Co-op', :close_after => true) { called += 1 }
    menu = open_root
    menu.select(1)
    tick(K::RETURN)
    child = menu.child_window
    assert_instance_of TestChildWindow, child
    tick
    tick(K::RETURN)
    assert_equal 1, child.confirmations
    tick
    tick(K::ESC)
    assert child.disposed?
    menu.select(2)
    tick
    tick(K::RETURN)
    assert_equal 1, called
    assert_nil root
  end
  def open_definition(item)
    menu = open_root
    item.on_ok(menu)
    tick
    menu.child_window
  end
  def select_item(window, id)
    window.select(window.definition.items.index { |item| item.identifier == id })
  end
  def test_declarative_items_nested_windows_and_persistent_values
    builds = 0
    item = M.submenu('Settings') do |m|
      builds += 1
      m.header('Display')
      m.toggle('Names', :key => 'test.names', :default => true)
      m.slider('Size', :min => 8, :max => 32, :step => 2, :default => 16)
      m.choice('Mode', :values => [:a, :b], :default => :a)
      m.submenu('Advanced') { |child| child.action('Done', :close_after => true) {} }
    end
    assert_equal 1, builds
    sub = open_definition(item)
    assert_equal ['Co-op', 'General'], M.categories
    assert_equal 2, sub.index # title and header are skipped
    tick(K::RETURN)
    assert_equal false, M['test.names']
    select_item(sub, 'Size')
    tick(K::RIGHT)
    assert_equal 18, sub.current_ext.value
    select_item(sub, 'Mode')
    tick(K::RIGHT)
    assert_equal :b, sub.current_ext.value
    select_item(sub, 'Advanced')
    tick(K::RETURN)
    child = sub.child_window
    assert_instance_of ModMenu_SubmenuWindow, child
    tick
    tick(K::RETURN)
    assert child.disposed?
    assert sub.active
    tick
    tick(K::ESC)
    assert sub.disposed?
    item.on_ok(root)
    sub = root.child_window
    select_item(sub, 'Size')
    assert_equal 18, sub.current_ext.value
    assert_equal 1, builds
  end
  def test_dynamic_rebuild_retains_selection_and_child_and_closes_invalid_subject
    rows = [[1, 'First'], [2, 'Second']]
    valid = true
    builds = 0
    item = M.submenu('Dynamic', :refresh => proc { rows.map(&:dup) }, :valid => proc { valid }) do |m|
      builds += 1
      rows.each { |id, name| m.submenu(name, :id => id) { |child| child.action('Wait') {} } }
    end
    assert_equal 0, builds
    sub = open_definition(item)
    select_item(sub, 2)
    tick(K::RETURN)
    child = sub.child_window
    rows.unshift([3, 'New'])
    rows.last[1] = 'Renamed'
    tick
    assert_equal 2, sub.current_ext.identifier
    assert_equal 'Renamed', sub.current_ext.label
    assert_same child, sub.child_window
    assert_equal 2, builds
    3.times { tick }
    assert_equal 2, builds
    valid = false
    tick
    assert sub.disposed?
    assert child.disposed?
    assert root.active
  end
  def test_action_failure_enabled_predicate_and_close_all
    allowed = false
    success = false
    calls = 0
    item = M.submenu('Actions') do |m|
      m.action('Run', :enabled => proc { allowed }, :close_after => :all) { calls += 1; success }
    end
    sub = open_definition(item)
    select_item(sub, 'Run')
    sub.process_ok
    assert_equal 0, calls
    allowed = true
    sub.process_ok
    assert_equal 1, calls
    refute root.closing
    success = true
    sub.process_ok
    tick
    assert_nil root
    assert sub.disposed?
  end
  def test_language_change_rebuilds_dynamic_content_without_resetting_selection
    language = :en
    original = M.method(:language)
    M.define_singleton_method(:language) { language }
    builds = 0
    item = M.submenu('Language', :refresh => proc { 0 }) do |m|
      builds += 1
      m.action(language.to_s, :id => :stable, :translate => false) {}
    end
    sub = open_definition(item)
    language = :ru
    tick
    assert_equal 2, builds
    assert_equal :stable, sub.current_ext.identifier
    assert_equal 'ru', sub.current_ext.label_text
  ensure
    M.define_singleton_method(:language, original)
  end

  def test_category_replaces_only_its_own_items
    M.category('Shared', :id => :first) { |m| m.header('Old'); m.action('A') {} }
    M.category('Shared', :id => :second) { |m| m.action('B') {} }
    M.action('Legacy', :category => 'Shared') {}
    M.category('Shared', :id => :first) { |m| m.submenu('New') { |child| child.header('Inner') } }
    assert_equal ['B', 'Legacy', 'New'], M.items_for('Shared').map(&:label)
    assert_equal 1, M.categories.count('Shared')
  end

  def backdrop_parts(window)
    backdrop = window.instance_variable_get(:@backdrop)
    [:panel, :shade, :pixel].map { |name| backdrop.instance_variable_get("@#{name}") }
  end

  def test_nested_backdrops_cover_parents_and_are_released_with_their_owners
    menu = open_root
    child = menu.open_child(TestChildWindow.new)
    grandchild = child.open_child(TestChildWindow.new)
    child_parts = backdrop_parts(child)
    grandchild_parts = backdrop_parts(grandchild)
    [[menu, child, child_parts], [child, grandchild, grandchild_parts]].each do |parent, window, parts|
      panel, shade, pixel = parts
      assert_operator shade.z, :>, parent.z
      assert_operator panel.z, :>, shade.z
      assert_operator window.z, :>, panel.z
      assert_same pixel, panel.bitmap
      assert_same pixel, shade.bitmap
    end
    grandchild.x += 20
    grandchild.width += 30
    tick
    panel = grandchild_parts.first
    assert_operator panel.x, :>, grandchild.x
    assert_operator panel.x + panel.zoom_x, :<=, grandchild.x + grandchild.width
    child.close_child
    assert grandchild_parts.all?(&:disposed?)
    refute child_parts.any?(&:disposed?)
    assert child.active
    resources = [menu, child, menu.instance_variable_get(:@header),
                 menu.instance_variable_get(:@description_window)].flat_map { |w| backdrop_parts(w).compact }
    @scene.terminate
    assert resources.all?(&:disposed?)
  end

  def test_description_follows_focused_window_and_live_text_without_repainting_every_frame
    text = 'Before'
    item = M.submenu('Settings', :description => 'Open settings') do |m|
      m.action('Live', :description => proc { text }) {}
      m.action('No description') {}
    end
    sub = open_definition(item)
    description = root.instance_variable_get(:@description_window)
    assert_equal 'Before', description.instance_variable_get(:@text)
    clears = description.contents.clears
    3.times { tick }
    assert_equal clears, description.contents.clears
    text = 'После изменения'
    tick
    assert_equal text, description.instance_variable_get(:@text)
    select_item(sub, 'No description')
    tick
    assert_equal '', description.instance_variable_get(:@text)
    sub.open_child(TestChildWindow.new)
    tick
    assert_equal '', description.instance_variable_get(:@text)
    assert_operator description.z, :>, sub.child_window.z
    sub.close_child
    root.close_child
    tick
    assert_equal root.description_text, description.instance_variable_get(:@text)
  end

  def test_description_translates_independently_of_player_name
    item = M::Item.new('Player', :translate => false, :description => 'help.player')
    M.stub(:tr, proc { |key| key == 'help.player' ? 'Действия игрока' : 'wrong' }) do
      assert_equal 'Player', item.label_text
      assert_equal 'Действия игрока', item.description_text
    end
  end

  def test_description_wraps_words_newlines_and_long_unicode_tokens
    description = ModMenu_DescriptionWindow.new(0, 0, 144)
    description.set('') # apply the description font size
    assert_equal ['Первое слово', 'Вторая', 'строка'], description.wrap("Первое слово\nВторая строка")
    token = '界' * 30
    lines = description.wrap(token)
    assert_equal token, lines.join
    assert lines.all? { |line| description.text_size(line).width <= description.contents.width }
  ensure
    description.dispose if description
  end

  def test_description_only_measures_visible_words_and_keeps_overflow_ellipsis
    description = ModMenu_DescriptionWindow.new(0, 0, 520)
    draws, measurements = [], []
    measure = description.method(:text_size)
    description.define_singleton_method(:text_size) do |text|
      measurements << text
      measure.call(text)
    end
    description.define_singleton_method(:draw_text) { |*args| draws << args }
    text = 'Подробное описание предмета с историей и свойствами. ' * 80
    description.set(text)
    assert_equal 3, draws.size
    assert draws.last[4].end_with?('...')
    assert_operator measurements.size, :<, 60
    count = measurements.size
    description.set(text)
    assert_equal count, measurements.size
    assert_equal 3, draws.size
  ensure
    description.dispose if description
  end

  def test_limited_description_wrap_keeps_same_visible_lines_for_unicode_and_newlines
    description = ModMenu_DescriptionWindow.new(0, 0, 144)
    description.set('')
    ["Первое слово\n\nВторая строка\nТретья строка\nЕщё строка", '界' * 100].each do |text|
      assert_equal description.wrap(text).first(4), description.wrap(text, 4)
    end
  ensure
    description.dispose if description
  end

  def test_description_and_long_submenus_fit_a_small_screen
    Graphics.stub(:height, 416) do
      item = M.submenu('Long list') { |m| 50.times { |i| m.action(i.to_s) {} } }
      sub = open_definition(item)
      description = root.instance_variable_get(:@description_window)
      assert_operator root.instance_variable_get(:@header).y, :>=, 0
      assert_operator description.y + description.height, :<=, Graphics.height
      assert_operator sub.y, :>=, 0
      assert_operator sub.y + sub.height, :<, description.y
      assert_operator sub.visible_line_number, :<, sub.item_max
    end
  end

  def test_adjusting_a_slider_redraws_its_siblings_without_resetting_scroll
    M.header('First section', :category => 'Co-op')
    first = M.slider('First', :category => 'Co-op', :default => 0, :max => 10)
    M.slider('Second', :category => 'Co-op', :default => 0, :max => 10)
    M.header('Other section', :category => 'Co-op')
    M.slider('Unrelated', :category => 'Co-op', :default => 0, :max => 10)
    menu = open_root
    menu.select(2)
    menu.top_row = 1
    redrawn = []
    menu.define_singleton_method(:redraw_item) { |index| redrawn << index }

    tick(K::RIGHT)

    assert_equal 1, first.value
    assert_equal [2, 3], redrawn
    assert_equal 2, menu.index
    assert_equal 1, menu.top_row
  end

end
