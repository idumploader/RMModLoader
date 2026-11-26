require 'tmpdir'
require 'fileutils'
require_relative 'support/modmenu_rgss'
load File.expand_path('../mod_loader/framework/core/nvram.rb', __dir__)

class ModMenuNavigationTest < Minitest::Test
  M = ModLoader::ModMenu

  class CountingStore < ModLoader::NVRAMStore
    def writes; @writes || 0; end
    def save
      @writes = writes + 1
      super
    end
  end

  def setup
    @dir = Dir.mktmpdir('modmenu-navigation-')
    @path = File.join(@dir, 'nvram.dat')
    @store = CountingStore.new(@path)
    ModLoader.instance_variable_set(:@nvram, @store)
    M.reset_registry
    ModLoader::InputCapture.reset
    ModLoader.held = ModLoader.triggered = []
    @scene = Scene_Base.new
    @calls = 0
    install_tabs
  end

  def teardown
    @scene.terminate
    M.reset_registry
    FileUtils.remove_entry(@dir)
  end

  def install_tabs
    ['First', 'Second'].each do |name|
      M.category(name, :id => :navigation_test) do |menu|
        24.times do |i|
          menu.action("#{name} #{i}", :id => i) { @calls += 1 }
        end
      end
    end
  end

  def open_menu
    Graphics.frame_count += 1 # closing-key capture lasts through the old frame
    @scene.modmenu_open_window
    @scene.instance_variable_get(:@modmenu_window)
  end

  def close_menu
    @scene.modmenu_dispose_window
  end

  def test_each_tab_restores_its_own_selection_and_scroll
    menu = open_menu
    menu.select(14)
    menu.top_row = 10
    menu.switch_category(1)
    menu.select(15)
    menu.top_row = 5
    menu.switch_category(-1)
    assert_equal ['First', 14, 10], [menu.category, menu.current_ext.identifier, menu.top_row]
    menu.switch_category(1)
    assert_equal ['Second', 15, 5], [menu.category, menu.current_ext.identifier, menu.top_row]
    assert_equal 0, @store.writes
    close_menu
    assert_equal 1, @store.writes

    menu = open_menu
    assert_equal ['Second', 15, 5], [menu.category, menu.current_ext.identifier, menu.top_row]
    assert_equal 0, @calls
    close_menu
    assert_equal 1, @store.writes # reopening without moving does not rewrite NVRAM
  end

  def test_navigation_survives_a_new_store_and_reordered_tabs_and_items
    menu = open_menu
    menu.switch_category(1)
    menu.select(15)
    menu.top_row = 5
    close_menu
    M.reset_registry
    @store = CountingStore.new(@path)
    ModLoader.instance_variable_set(:@nvram, @store)
    M.category('Second', :id => :navigation_test) do |tab|
      tab.action('Renamed item', :id => 15) { @calls += 1 }
      tab.action('Other item', :id => 0) {}
    end
    M.action('First tab action', :category => 'First') {}

    menu = open_menu
    assert_equal 'Second', menu.category
    assert_equal 15, menu.current_ext.identifier
    assert_equal 'Renamed item', menu.current_ext.label
    assert_equal 0, menu.index
    assert_equal 0, @calls
  end

  def test_missing_or_disabled_saved_item_falls_back_to_first_enabled
    menu = open_menu
    menu.select(14)
    menu.top_row = 10
    close_menu
    M.category('First', :id => :navigation_test) do |tab|
      tab.header('Heading')
      tab.action('Disabled', :id => 14, :enabled => false) {}
      tab.action('Available', :id => :available) {}
    end
    menu = open_menu
    assert_equal :available, menu.current_ext.identifier
    assert_equal 0, menu.top_row
    close_menu
    M.category('First', :id => :navigation_test) do |tab|
      tab.header('Heading')
      tab.action('New item', :id => :new) {}
    end
    menu = open_menu
    assert_equal :new, menu.current_ext.identifier
    assert_equal 0, menu.top_row
  end

  def test_missing_saved_tab_falls_back_to_an_available_tab
    menu = open_menu
    menu.switch_category(1)
    close_menu
    M.reset_registry
    M.action('Replacement', :category => 'Replacement tab') {}
    menu = open_menu
    assert_equal 'Replacement tab', menu.category
    assert_equal 'Replacement', menu.current_ext.identifier
  end

  def test_scene_exit_and_direct_disposal_save_before_graphics_are_released
    menu = open_menu
    menu.select(14)
    @scene.terminate
    assert menu.disposed?
    assert_equal 1, @store.writes
    @scene = Scene_Base.new
    menu = open_menu
    assert_equal 14, menu.current_ext.identifier
    menu.select(15)
    menu.dispose
    assert_equal 2, @store.writes
    menu = open_menu
    assert_equal 15, menu.current_ext.identifier
  end

  def test_closing_a_child_stack_restores_the_parent_item_without_opening_it
    M.submenu('Child', :category => 'First', :id => :child) do |tab|
      tab.action('Run') { @calls += 1 }
    end
    menu = open_menu
    menu.select(24)
    menu.current_ext.on_ok(menu)
    child = menu.child_window
    close_menu
    assert child.disposed?
    menu = open_menu
    assert_equal :child, menu.current_ext.identifier
    assert_nil menu.child_window
    assert_equal 0, @calls
  end
end
