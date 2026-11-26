require 'tmpdir'
require 'fileutils'
# Load the engine fixture BEFORE ModMenu so the real resetter can restore its
# original Input/Scene methods, then re-evaluate scripts from an isolated dir.
fixture = File.join(__dir__, 'support/modmenu_rgss.rb')
eval(File.read(fixture).split("load File.expand_path").first, TOPLEVEL_BINDING, fixture)
load File.expand_path('../mod_loader/framework/loader.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/capture.rb', __dir__)
resetter = File.expand_path('../mod_loader/framework/core/resetter.rb', __dir__)
eval(File.read(resetter).split("\nModResetter.snapshot_all_if_needed").first + "\nend\n", TOPLEVEL_BINDING, resetter)
ModResetter.instance_variable_set(:@classes_snapshot,
  [Input, Scene_Base].map { |cls| ModResetter.snapshot_for_class(cls, cls.name.to_sym) })

class ModMenuResetTest < Minitest::Test
  def test_reload_closes_windows_clears_registry_and_preserves_settings
    Dir.mktmpdir do |dir|
      scripts = File.join(dir, 'scripts')
      Dir.mkdir(scripts)
      File.write(File.join(scripts, '10 - ModMenu Fixture.rb'), "ModLoader::Framework.load('modmenu/bootstrap.rb')")
      FileUtils.cp_r(File.expand_path('../mod_loader/framework', __dir__), dir)
      File.write(File.join(scripts, '12 - Register.rb'), <<'CODE')
ModLoader::ModMenu.category('Test', :id => :fixture) do |m|
  m.submenu('Child') { |child| child.toggle('Flag', :key => 'reset.flag', :default => true) }
end
ModLoader::ModMenu.action('Legacy action', :category => 'Test') {}
CODE
      ModLoader.define_singleton_method(:data_directory) { dir }
      warnings = $VERBOSE
      $VERBOSE = nil # reloaded class constants intentionally retain their names
      ModResetter.execute_all_scripts
      m = ModLoader::ModMenu
      3.times do
        ModLoader::InputCapture.reset
        scene = Scene_Base.new
        scene.modmenu_open_window
        root = scene.instance_variable_get(:@modmenu_window)
        m.items_for('Test').first.on_ok(root)
        child = root.child_window
        child.definition.items[1].value = false
        ModResetter.restore_snapshot
        assert root.disposed?
        assert child.disposed?
        ModResetter.execute_all_scripts
        assert_equal ['Test'], m.categories
        assert_equal ['Child', 'Legacy action'], m.items_for('Test').map(&:label)
        assert_equal false, m['reset.flag']
        refute m.active?
        assert_nil ModLoader::InputCapture.owner
        assert_equal 1, ModResetter.instance_variable_get(:@before_reload).size
      end
    ensure
      $VERBOSE = warnings
    end
  end
end
