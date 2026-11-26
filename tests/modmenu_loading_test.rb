# Native script eval supplies a basename rather than an absolute __FILE__.
fixture = File.join(__dir__, 'support/modmenu_rgss.rb')
eval(File.read(fixture).split("load File.expand_path").first, TOPLEVEL_BINDING, fixture)
load File.expand_path('../mod_loader/framework/loader.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/capture.rb', __dir__)
module ModLoader
  def self.data_directory
    File.expand_path('../mod_loader', File.dirname(__FILE__))
  end
end
MODMENU_ENTRYPOINT = "ModLoader::Framework.load('modmenu/bootstrap.rb')"
eval(MODMENU_ENTRYPOINT, TOPLEVEL_BINDING, '10 - ModMenu.rb')

class ModMenuLoadingTest < Minitest::Test
  def test_native_basename_loads_all_components_once
    original = Scene_Base.instance_method(:update_basic)
    eval(MODMENU_ENTRYPOINT, TOPLEVEL_BINDING, '10 - ModMenu.rb')
    assert_equal original, Scene_Base.instance_method(:update_basic)
    assert defined?(ModLoader::ModMenu::MenuDefinition)
    assert defined?(ModMenu_ListWindow)
    assert Scene_Base.method_defined?(:modmenu_open_window)
    item = ModLoader::ModMenu.action('Loaded through native entrypoint') {}
    assert_includes ModLoader::ModMenu.items_for('General'), item
  end
end
