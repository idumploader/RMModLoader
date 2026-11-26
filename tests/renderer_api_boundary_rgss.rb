# Run only in the isolated native renderer fixture, on real RGSS Ruby 1.9.2.
module RendererApiBoundary
  class ConvertingCount
    def initialize(&action); @action = action; end
    def to_int; @action.call; end
  end

  def self.check(condition, message)
    raise message unless condition
  end

  def self.run
    viewport = Viewport.new(0, 0, 32, 32)
    bitmap = Bitmap.new(32, 32)
    begin
      Graphics.update
      check(ModLoader.parallel_renderer_capture(viewport), 'Initial capture failed')
      count = ConvertingCount.new { bitmap.dispose; 1 }
      check(ModLoader.parallel_renderer_start(bitmap, count) == false,
            'Disposed Bitmap in to_int was accepted')
      check(ModLoader.parallel_renderer_status.include?('Object has no live native resource'),
            'Bitmap invalidation was not diagnosed after conversion')

      bitmap = Bitmap.new(32, 32)
      count = ConvertingCount.new { viewport.dispose; 1 }
      check(ModLoader.parallel_renderer_submit(viewport, bitmap, count) == false,
            'Disposed Viewport in to_int was accepted')
      check(ModLoader.parallel_renderer_status.include?('disposed') ||
            ModLoader.parallel_renderer_status.include?('live native resource'),
            'Viewport invalidation was not diagnosed after conversion')

      viewport = Viewport.new(0, 0, 32, 32)
      Graphics.update
      check(ModLoader.parallel_renderer_capture(viewport), 'Capture after failed decode failed')
      sentinel = RuntimeError.new('to_int boundary sentinel')
      count = ConvertingCount.new { raise sentinel }
      caught = nil
      begin
        ModLoader.parallel_renderer_start(bitmap, count)
      rescue RuntimeError => error
        caught = error
      end
      check(caught.equal?(sentinel), 'Ruby conversion exception was replaced or swallowed')
      check(ModLoader.parallel_renderer_start(bitmap, 1), 'Start after Ruby exception failed')
      check(ModLoader.parallel_renderer_collect(bitmap), 'Collect after Ruby exception failed')
      check(ModLoader.render_snapshot_probe_clear, 'Legacy clear alias failed')
      puts 'API_BOUNDARY numeric conversion, disposed resources, exception propagation and legacy alias PASS'
    ensure
      ModLoader.parallel_renderer_frame_mode(0)
      viewport.dispose if viewport && !viewport.disposed?
      bitmap.dispose if bitmap && !bitmap.disposed?
    end

    # Test the reload order with grouped names on the actual Ruby 1.9 runtime.
    resetter = File.join(ModLoader.data_directory, 'framework', 'core', 'resetter.rb')
    unless defined?(ModResetter)
      eval(File.read(resetter).split("\nModResetter.snapshot_all_if_needed").first + "\nend\n",
           TOPLEVEL_BINDING, resetter)
    end
    directory = File.join(ModLoader.data_directory, 'api-order-fixture')
    Dir.mkdir(directory) unless File.directory?(directory)
    scripts = File.join(directory, 'scripts')
    Dir.mkdir(scripts) unless File.directory?(scripts)
    names = ['990 - ModLoader Runtime.rb', '245 - ModLoader Backend.rb', '1 - ModLoader Core.rb']
    original_directory = ModLoader.data_directory
    begin
      names.each do |name|
        File.open(File.join(scripts, name), 'wb') { |file| file.write("$api_boundary_order << #{name.inspect}\n") }
      end
      ModLoader.define_singleton_method(:data_directory) { directory }
      2.times do
        $api_boundary_order = []
        ModResetter.execute_all_scripts
        check($api_boundary_order == names.reverse, 'Grouped reload order differs from native order')
      end
      puts 'API_BOUNDARY grouped script reload order on RGSS Ruby PASS'
    ensure
      ModLoader.define_singleton_method(:data_directory) { original_directory }
      names.each { |name| File.delete(File.join(scripts, name)) if File.exist?(File.join(scripts, name)) }
      Dir.rmdir(scripts)
      Dir.rmdir(directory)
      $api_boundary_order = nil
    end
  end
end
