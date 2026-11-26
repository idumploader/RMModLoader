require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
load File.expand_path('../mod_loader/framework/core/nvram.rb', __dir__)

class FailingNVRAMStore < ModLoader::NVRAMStore
  attr_accessor :fail_write
  def save
    raise IOError, 'simulated write failure' if fail_write
    super
  end
end

class ModLoaderNVRAMTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @store = FailingNVRAMStore.new(File.join(@directory, 'nvram.dat'))
  end
  def teardown
    FileUtils.remove_entry(@directory)
  end
  def test_failed_assignment_preserves_absent_and_nil_keys
    @store[:nil_value] = nil
    @store.fail_write = true
    assert_raises(IOError) { @store[:new_value] = 1 }
    refute @store.key?(:new_value)
    assert_raises(IOError) { @store[:nil_value] = 2 }
    assert @store.key?(:nil_value)
    assert_nil @store[:nil_value]
  end
  def test_failed_section_commit_keeps_backing_value_and_allows_retry
    @store[:display] = { :limit => 256 }
    previous = @store[:display]
    shallow = @store.to_h
    section = @store.section(:display)
    section[:limit] = 192
    @store.fail_write = true
    assert_raises(IOError) { section.commit }
    assert_same previous, @store[:display]
    assert_same previous, shallow[:display]
    assert_equal 256, @store[:display][:limit]
    assert_equal 192, section[:limit]
    assert section.dirty?
    @store.fail_write = false
    assert_same section, section.save
    refute section.dirty?
    assert_equal 192, @store[:display][:limit]
    persisted = ModLoader::NVRAMStore.new(File.join(@directory, 'nvram.dat'))
    assert_equal 192, persisted[:display][:limit]
  end
  def test_caller_rollback_after_failed_commit_keeps_section_and_store_consistent
    @store[:input] = { :port => 27420 }
    section = @store.section(:input)
    previous = section[:port]
    @store.fail_write = true
    section[:port] = 27421
    assert_raises(IOError) { section.commit }
    section[:port] = previous
    refute section.dirty?
    assert_equal previous, @store[:input][:port]
  end
  def test_failed_delete_and_clear_restore_values_and_memoized_sections
    @store[:present_nil] = nil
    @store[:display] = { :limit => 256 }
    section = @store.section(:display)
    previous = @store[:display]
    @store.fail_write = true
    assert_raises(IOError) { @store.delete(:present_nil) }
    assert @store.key?(:present_nil)
    assert_nil @store[:present_nil]
    assert_raises(IOError) { @store.clear }
    assert @store.key?(:present_nil)
    assert_same previous, @store[:display]
    assert_same section, @store.section(:display)
    assert_nil @store.delete(:missing)
  end
end
