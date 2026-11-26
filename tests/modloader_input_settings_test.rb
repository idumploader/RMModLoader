require_relative 'support/modmenu_rgss'
require 'tmpdir'

# Use real virtual keys and the real editor/persistence with inert RGSS drawing.
ModLoader::Keyboard.constants.each { |key| ModLoader::Keyboard.send(:remove_const, key) }
load File.expand_path('../mod_loader/framework/input/keyboard.rb', __dir__)
load File.expand_path('../mod_loader/framework/input/line_input.rb', __dir__)
load File.expand_path('../mod_loader/framework/core/nvram.rb', __dir__)
module ModLoader
  class << self
    attr_accessor :test_store, :test_port, :listen_calls, :stop_calls, :poll_calls, :listen_accepted
    def nvram; test_store; end
    def config_get(key); test_port; end
    def http_poll; @poll_calls = (@poll_calls || 0) + 1; nil; end
    def http_listen(port); (@listen_calls ||= []) << port; @listen_accepted != false; end
    def http_stop; @stop_calls = (@stop_calls || 0) + 1; nil; end
  end
  module TextInput
    def self.character(key); (0x30..0x39).include?(key) ? key.chr : ''; end
  end
end
load File.expand_path('../mod_loader/framework/input/settings.rb', __dir__)
load File.expand_path('../mod_loader/framework/http/router.rb', __dir__)

class ModLoaderInputSettingsTest < Minitest::Test
  S = ModLoader::InputSettings
  K = ModLoader::Keyboard
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'nvram.dat')
    ModLoader.test_store = ModLoader::NVRAMStore.new(@path)
    ModLoader.test_port = nil
    ModLoader.listen_calls = []
    ModLoader.stop_calls = ModLoader.poll_calls = 0
    ModLoader.listen_accepted = true
    ModLoader.held = ModLoader.triggered = []
    ModLoader::Http.instance_variable_set(:@started, false)
    ModLoader::Http.instance_variable_set(:@up, false)
    ModLoader::Http.instance_variable_set(:@port, nil)
    @windows = []
  end
  def teardown
    @windows.each { |window| window.dispose unless window.disposed? }
    FileUtils.remove_entry(@dir)
  end
  def editor
    window = ModLoader_HttpPortWindow.new
    @windows << window
    window.update # release of opening key arms editing
    window
  end
  def press(window, key)
    ModLoader.triggered = [key]
    window.update
    ModLoader.triggered = []
  end

  def test_default_config_and_saved_priority_after_reload
    assert_equal 27420, ModLoader::Http.configured_port
    ModLoader.test_port = 28000
    assert_equal 28000, ModLoader::Http.configured_port
    assert S.save_http_port('65535')
    ModLoader.test_store = ModLoader::NVRAMStore.new(@path)
    assert_equal 65535, ModLoader::Http.configured_port
    assert S.save_http_enabled(true)
    ModLoader::Http.tick
    assert_equal [65535], ModLoader.listen_calls
    assert S.save_http_port('1')
    ModLoader::Http.tick
    assert_equal [65535], ModLoader.listen_calls # applies on next launch
  end

  def test_http_is_off_by_default_and_does_not_poll_or_retry_while_off
    refute S.http_enabled?
    10.times { ModLoader::Http.tick }
    refute ModLoader::Http.running?
    assert_empty ModLoader.listen_calls
    assert_equal 0, ModLoader.poll_calls
    assert_equal 1, ModLoader.stop_calls
    [nil, 'true', 1].each do |invalid|
      S.settings[:http_enabled] = invalid
      refute S.http_enabled?
    end
  end

  def test_toggle_applies_immediately_and_survives_store_reload
    toggle = ModLoader::ModMenu.items_for('Debug').find { |entry| entry.identifier == :http_enabled }
    assert toggle.selectable?
    refute toggle.value
    toggle.on_ok(nil)
    assert toggle.value
    assert_equal [27420], ModLoader.listen_calls
    ModLoader.test_store = ModLoader::NVRAMStore.new(@path)
    assert S.http_enabled?
    ModLoader::Http.stop
    ModLoader::Http.instance_variable_set(:@started, false)
    ModLoader::Http.tick
    assert toggle.value
    toggle.on_ok(nil)
    refute toggle.value
    ModLoader.test_store = ModLoader::NVRAMStore.new(@path)
    refute S.http_enabled?
    ModLoader::Http.instance_variable_set(:@started, false)
    ModLoader::Http.tick
    refute ModLoader::Http.running?
    assert_equal [27420, 27420], ModLoader.listen_calls
  end

  def test_next_enable_uses_saved_port_without_replacing_routes
    routes = ModLoader::Http.routes.dup
    assert S.save_http_enabled(true)
    assert S.save_http_port('28001')
    assert_equal 27420, ModLoader::Http.port
    assert S.save_http_enabled(false)
    assert S.save_http_enabled(true)
    assert_equal [27420, 28001], ModLoader.listen_calls
    assert_equal 28001, ModLoader::Http.port
    assert_equal routes, ModLoader::Http.routes
  end

  def test_failed_listen_stays_off_without_saving_or_retrying_each_frame
    ModLoader.listen_accepted = false
    refute S.save_http_enabled(true)
    refute S.http_running?
    refute S.http_enabled?
    refute S.settings.key?(:http_enabled)
    3.times { ModLoader::Http.tick }
    assert_equal [27420], ModLoader.listen_calls
    ModLoader.listen_accepted = true
    assert S.save_http_enabled(true)
    assert S.http_running?
  end

  def test_failed_enable_save_restores_off_and_the_absent_preference
    S.settings.define_singleton_method(:commit) { raise IOError, 'test write failure' }
    refute S.save_http_enabled(true)
    refute S.http_running?
    refute S.settings.key?(:http_enabled)
    refute ModLoader::NVRAMStore.new(@path).section(:input).key?(:http_enabled)
  end

  def test_failed_disable_save_restores_running_server_on_its_original_port
    assert S.save_http_enabled(true)
    assert S.save_http_port('28001')
    S.settings.define_singleton_method(:commit) { raise IOError, 'test write failure' }
    refute S.save_http_enabled(false)
    assert S.http_running?
    assert S.http_enabled?
    assert_equal [27420, 27420], ModLoader.listen_calls
    assert_equal 27420, ModLoader::Http.port
    assert_equal 28001, S.http_port
    assert_equal true, ModLoader::NVRAMStore.new(@path).section(:input)[:http_enabled]
  end

  def test_invalid_values_do_not_overwrite_saved_port
    assert S.save_http_port('27421')
    ['', '0', '-1', '65536', '655350', 'abc', '12x', ' 123', "123\n", 123].each do |value|
      refute S.save_http_port(value), value.inspect
      assert_equal 27421, S.http_port
    end
    ModLoader.test_store = ModLoader::NVRAMStore.new(@path)
    assert_equal 27421, S.http_port
  end

  def test_invalid_config_or_saved_values_use_valid_fallback
    [0, -1, 65536, '27420', nil].each do |value|
      ModLoader.test_port = value
      S.settings[:http_port] = value
      assert_equal 27420, ModLoader::Http.configured_port
    end
  end

  def test_editor_types_saves_and_cancel_discards
    window = editor
    window.instance_variable_get(:@line).replace('')
    '28001'.each_byte { |key| press(window, key) }
    press(window, K::RETURN)
    assert window.closing
    assert_equal 28001, S.http_port
    cancelled = editor
    press(cancelled, K::BACK)
    press(cancelled, K::ESC)
    assert cancelled.closing
    assert_equal 28001, S.http_port
  end

  def test_invalid_submission_keeps_editor_open_and_port_unchanged
    window = editor
    window.instance_variable_get(:@line).replace('65536')
    press(window, K::RETURN)
    refute window.closing
    assert_equal 27420, S.http_port
    assert_match(/Could not save/, window.description_text)
  end

  def test_save_failure_restores_previous_setting
    assert S.save_http_port('28000')
    S.settings.define_singleton_method(:commit) { raise IOError, 'test write failure' }
    refute S.save_http_port('28001')
    assert_equal 28000, S.http_port
  end

  def test_menu_opens_owned_child_and_refreshes_port_on_save
    item = ModLoader::ModMenu.items_for('Debug').find { |entry| entry.label == 'HTTP port' }
    assert item.selectable?
    parent = TestChildWindow.new
    @windows << parent
    item.on_ok(parent)
    child = parent.child_window
    assert_instance_of ModLoader_HttpPortWindow, child
    child.update
    child.instance_variable_get(:@line).replace('28002')
    press(child, K::RETURN)
    parent.update
    assert_nil parent.child_window
    assert parent.active
    assert_equal 28002, S.http_port
  end
end
