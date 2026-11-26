require 'minitest/autorun'
load File.expand_path('../mod_loader/framework/input/clipboard.rb', __dir__)

# Observe native ownership rules without reading or changing the host clipboard.
class ClipboardNativeFixture
  attr_accessor :source, :fail, :reported_size, :raise_on
  attr_reader :calls, :published

  def initialize
    @calls, @memory, @locked = [], {}, {}
    @published = 'previous clipboard'
  end

  def call(name, *args)
    @calls << [name, *args]
    raise 'native copy failed' if name == @raise_on
    return 0 if name == @fail
    case name
    when :active_window then 123
    when :open
      raise 'missing clipboard window' if args[0] == 0
      @opened = true
      1
    when :close
      raise 'closing a locked handle' unless @locked.empty?
      @opened = false
      1
    when :get
      raise 'reading a closed clipboard' unless @opened
      @source ? 7 : 0
    when :size then @reported_size || @source.bytesize
    when :alloc
      raise 'clipboard memory must be moveable' unless args[0] == 2
      @memory[8] = "\0" * args[1]
      8
    when :lock
      @locked[args[0]] = true
      args[0] * 100
    when :unlock
      raise 'unlock without lock' unless @locked.delete(args[0])
      1
    when :read_memory
      raise 'read without lock' unless @locked[7]
      args[0].replace(@source)
    when :write_memory
      raise 'write without lock' unless @locked[8]
      @memory[8] = args[1].dup
    when :empty
      raise 'emptying a closed clipboard' unless @opened
      @published = nil
      1
    when :set
      raise 'publishing a closed clipboard' unless @opened
      raise 'wrong clipboard format' unless args[0] == 13
      @published = @memory.fetch(args[1]).dup
      args[1]
    when :free
      raise 'freeing borrowed memory' unless args[0] == 8
      raise 'freeing locked memory' if @locked[8]
      @memory.delete(8)
      0
    else
      raise "unexpected API #{name}"
    end
  end
end

class ModLoaderClipboardTest < Minitest::Test
  C = ModLoader::Clipboard
  def setup; @native = ClipboardNativeFixture.new; end
  def native; C.stub(:call, @native.method(:call)) { yield }; end
  def calls; @native.calls.map(&:first); end

  def test_reads_null_terminated_utf16_on_code_unit_boundaries_and_releases_borrow
    @native.source = [0x0100, 0x044F, 0xD83D, 0xDE00, 0, 0x0041].pack('v*')
    value = native { C.read }
    assert_equal 'Āя😀', value
    assert_equal Encoding::UTF_8, value.encoding
    assert_equal [:active_window, :open, :get, :size, :lock, :read_memory, :unlock, :close], calls
    assert_equal 'previous clipboard', @native.published
  end

  def test_read_replaces_an_invalid_surrogate_and_handles_empty_text
    @native.source = [0xD800, 0].pack('v*')
    assert_equal '�', native { C.read }
    @native.source = "\0\0"
    assert_equal '', native { C.read }
  end

  def test_busy_clipboard_or_missing_window_does_not_open_or_close_another_owner
    [:open, :active_window].each do |failure|
      @native = ClipboardNativeFixture.new
      @native.fail = failure
      assert_nil native { C.read }
      refute_includes calls, :close
      refute_includes calls, :get
    end
  end

  def test_unavailable_text_or_lock_still_closes_the_clipboard
    assert_nil native { C.read }
    assert_equal :close, calls.last
    @native.source = "\0\0"
    @native.fail = :lock
    assert_nil native { C.read }
    assert_equal :close, calls.last
    refute_includes calls, :unlock
  end

  def test_oversized_data_is_not_copied_and_unterminated_text_is_not_decoded
    @native.source = [0x41, 0x42].pack('v*')
    @native.reported_size = C::MAX_READ_BYTES + 1
    assert_nil native { C.read }
    refute_includes calls, :lock
    @native.reported_size = nil
    assert_nil native { C.read }
    assert_equal [:unlock, :close], calls.last(2)
  end

  def test_read_failure_unlocks_and_closes_without_freeing_borrowed_memory
    @native.source = "\0\0"
    @native.raise_on = :read_memory
    assert_raises(RuntimeError) { native { C.read } }
    assert_equal [:unlock, :close], calls.last(2)
    refute_includes calls, :free
  end

  def test_write_publishes_utf16_with_terminator_and_transfers_memory_to_windows
    assert native { C.write('я😀') }
    assert_equal [0x044F, 0xD83D, 0xDE00, 0].pack('v*'), @native.published
    assert_equal [:alloc, :lock, :write_memory, :unlock, :active_window, :open, :empty, :set, :close], calls
    assert_equal [:set, 13, 8], @native.calls.find { |entry| entry.first == :set }
    refute_includes calls, :free
  end

  def test_write_failures_free_only_untransferred_memory_and_close_only_if_opened
    [:alloc, :lock, :active_window, :open, :empty, :set].each do |failure|
      @native = ClipboardNativeFixture.new
      @native.fail = failure
      refute native { C.write('new') }, failure.to_s
      assert_equal(failure != :alloc, calls.include?(:free), failure.to_s)
      assert_equal([:empty, :set].include?(failure), calls.include?(:close), failure.to_s)
      assert_equal 'previous clipboard', @native.published unless failure == :set
    end
  end

  def test_write_copy_failure_unlocks_and_frees_before_opening_clipboard
    @native.raise_on = :write_memory
    assert_raises(RuntimeError) { native { C.write('new') } }
    assert_equal [:unlock, :free], calls.last(2)
    refute_includes calls, :open
    assert_equal 'previous clipboard', @native.published
  end
end
