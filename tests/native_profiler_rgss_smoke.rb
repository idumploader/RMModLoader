# Run INSIDE the game after building the x86 DLL and deploying 995 - NativeProfiler.rb:
#   eval(File.read("path/to/tests/native_profiler_rgss_smoke.rb"))
#   NativeProfilerSmoke.run("mod_loader/profiler-smoke.json")
# The destination must not exist. This deliberately exercises VM/GC integration,
# which the standalone C++ and Ruby tests cannot validate.
module NativeProfilerSmoke
  def self.leaf
    "profile".upcase.reverse
  end

  def self.recursive(depth)
    depth > 0 ? recursive(depth - 1) : leaf
  end

  def self.native_exception
    Integer("not an integer")
  rescue ArgumentError
    leaf
  end

  def self.run(path)
    profiler = ModLoader::Profiler
    raise "native profiler unavailable" unless profiler.available?
    profiler.start(nil, :max_events => 100000)
    begin
      20.times { recursive(4) }
      fibers = 2.times.map do
        Fiber.new do
          recursive(2)
          Fiber.yield
          native_exception
        end
      end
      fibers.each { |fiber| fiber.resume }
      fibers.each { |fiber| fiber.resume }
      # Anonymous classes should stay valid in the native method table after GC.
      10.times do
        klass = Class.new { def profiler_temporary_method; 17; end }
        klass.new.profiler_temporary_method
      end
      klass = nil
      GC.start
      Graphics.update
      profiler.stop(false)
      profiler.save(path)
      text = File.read(path)
      raise "no native profile output" unless text.include?("rgss-native-profiler-v1")
      raise "Ruby methods not resolved" unless text.include?("recursive")
      raise "C methods not resolved" unless text.include?("upcase")
      raise "temporary class was lost" unless text.include?("profiler_temporary_method")
      # Exercise re-registration/removal while retaining the first saved report.
      profiler.start
      recursive(1)
      profiler.stop(false)
      profiler.discard
      puts "Native profiler smoke passed: #{path}"
      path
    ensure
      profiler.stop(false)
    end
  end
end
