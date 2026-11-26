# Execute in the real game, with the matching x86 DLL and render_snapshot_probe=true:
#   eval(File.read("path/to/tests/render_snapshot_rgss_smoke.rb"))
#   RenderSnapshotSmoke.run
# Standalone Ruby tests cannot validate RGSS vtables, iterators or pixel output.
module RenderSnapshotSmoke
  def self.pixels(bitmap)
    result = []
    bitmap.height.times do |y|
      bitmap.width.times do |x|
        c = bitmap.get_pixel(x, y)
        result << [c.red, c.green, c.blue, c.alpha]
      end
    end
    result
  end

  def self.verify_reference(mode, before, after)
    # Screen blitters can preserve destination alpha while changing RGB. An
    # alpha-only test incorrectly treats that valid render as an empty image.
    rgb_changes = 0
    alpha_changes = 0
    before.each_with_index do |pixel, index|
      current = after[index]
      rgb_changes += 1 if pixel[0, 3] != current[0, 3]
      alpha_changes += 1 if pixel[3] != current[3]
    end
    puts "#{mode}: reference changed RGB=#{rgb_changes}, alpha=#{alpha_changes} pixels"
    changed = rgb_changes > 0 || alpha_changes > 0
    raise "#{mode}: reference changed no pixel channels" if mode != :empty && !changed
    raise "empty: reference unexpectedly changed pixels" if mode == :empty && changed
    true
  end

  def self.check_case(mode, worker = false)
    probe = ModLoader::ParallelRenderer
    resources = []
    begin
      vp = Viewport.new(8, 6, 112, 80)
      resources << vp
      source = Bitmap.new(16, 16)
      resources << source
      source.fill_rect(0, 0, 8, 16, Color.new(230, 40, 70, 255))
      source.fill_rect(8, 0, 8, 16, Color.new(30, 180, 240, 128))
      sprites = []
      unless mode == :empty
        2.times do |i|
          sprite = Sprite.new(vp)
          resources << sprite
          sprites << sprite
          sprite.bitmap = source # sharing must be preserved with ONE pixel copy
          sprite.x, sprite.y, sprite.z = 12 + i * 18, 10 + i * 8, i
        end
        if mode == :transform
          sprites[0].zoom_x = 1.75
          sprites[0].zoom_y = 1.25
          sprites[0].mirror = true
          sprites[1].opacity = 140
          sprites[1].src_rect.set(2, 1, 12, 13)
        elsif mode == :wave
          sprites[0].wave_amp = 3
          sprites[0].wave_length = 30
          sprites[0].wave_speed = 0
          sprites[0].wave_phase = 45
        elsif mode == :tone
          vp.tone = Tone.new(10, -20, 30, 0)
          vp.color = Color.new(20, 60, 90, 50)
        end
      end
      reference = Bitmap.new(128, 96)
      result = Bitmap.new(128, 96)
      resources.concat([reference, result])
      background = Color.new(17, 23, 31, 73) if worker
      reference.fill_rect(reference.rect, background) if worker
      Graphics.update # resolve pending geometry and native drawlist order
      before = pixels(reference)
      probe.reference(vp, reference)
      expected = pixels(reference)
      verify_reference(mode, before, expected)
      probe.capture(vp)
      puts "#{mode}: #{probe.status}"
      if mode != :empty && !probe.status.include?('"surfaces":1')
        raise "#{mode}: shared source bitmap was not deduplicated"
      end
      if worker
        template = Bitmap.new(128, 96)
        resources << template
        template.fill_rect(template.rect, background)
        probe.start(template, 10000)
        template.dispose # worker must own both its target and source surfaces
        # A second submission must not replace or lose the in-flight job.
        rejected = false
        begin
          probe.start(result)
        rescue RuntimeError => error
          raise unless error.message.include?("pending")
          rejected = true
        end
        raise "worker accepted a second submission" unless rejected
        wrong_size = Bitmap.new(1, 1)
        resources << wrong_size
        rejected = false
        begin
          probe.collect(wrong_size)
        rescue RuntimeError => error
          raise unless error.message.include?("dimensions")
          rejected = true
        end
        raise "worker accepted wrong destination dimensions" unless rejected
        observed = false
        disposed_while_running = false
        8.times do |i|
          status = probe.status
          completed = status[/"worker_completed":(\d+)/, 1].to_i
          observed ||= completed > 0 && !status.include?('"worker_done":true')
          unless source.disposed?
            source.fill_rect(source.rect, Color.new(i * 30, 100, 30))
            sprites.each { |sprite| sprite.x += 1; sprite.opacity = 100 + i }
            vp.tone = Tone.new(i * 4, 0, 0, 0)
            if observed
              sprites.each { |sprite| sprite.dispose }
              vp.dispose
              source.dispose
              GC.start
              disposed_while_running = !probe.status.include?('"worker_done":true')
            end
          end
          Graphics.update # real main-thread rendering overlaps the worker
        end
        raise "#{mode}: did not observe active worker progress" unless observed
        raise "#{mode}: disposal did not overlap the worker" unless disposed_while_running
      end
      # Both pixel changes and complete original lifetime termination must leave
      # the snapshot untouched. Keeping a reference to the live bitmap fails this.
      source.clear unless source.disposed?
      sprites.each { |sprite| unless sprite.disposed?; sprite.x = 1000; sprite.dispose; end }
      vp.dispose unless vp.disposed?
      source.dispose unless source.disposed?
      GC.start
      if worker
        probe.collect(result)
        raise "#{mode}: worker snapshot pixels differ" unless pixels(result) == expected
        status = probe.status
        owner = status[/"owner_thread":(\d+)/, 1].to_i
        worker_id = status[/"last_worker_thread":(\d+)/, 1].to_i
        raise "worker did not run on a separate thread" if worker_id == 0 || worker_id == owner
        raise "worker did not finish all replays" unless status.include?('"last_worker_repeats":10000')
        puts "#{mode}: worker 10000 replays with concurrent disposal/Graphics.update PASS #{status}"
      end
      2.times do
        result.clear
        result.fill_rect(result.rect, background) if worker
        probe.draw(result)
        raise "#{mode}: snapshot pixels differ" unless pixels(result) == expected
      end
      # Walker must restore destination clip/offset for subsequent Bitmap writes.
      result.set_pixel(127, 95, Color.new(255, 255, 255, 255))
      raise "destination clip was not restored" unless result.get_pixel(127, 95).red == 255
      puts "#{mode}: #{probe.status} PASS"
    ensure
      probe.clear
      resources.reverse_each { |resource| resource.dispose unless resource.disposed? }
    end
  end

  def self.check_rejection
    probe = ModLoader::ParallelRenderer
    vp = Viewport.new(0, 0, 32, 32)
    source = Bitmap.new(8, 8)
    sprite = Sprite.new(vp)
    sprite.bitmap = source
    source.fill_rect(source.rect, Color.new(255, 0, 0))
    target = Bitmap.new(32, 32)
    begin
      Graphics.update
      probe.capture(vp)
      vp.zoom = 1.5
      Graphics.update
      rejected = false
      begin
        probe.capture(vp)
      rescue RuntimeError => error
        raise unless error.message.include?("Custom ViewportEffects")
        rejected = true
      end
      raise "custom viewport was accepted" unless rejected
      raise "failed capture retained a stale snapshot" unless probe.status.include?('"captured":false')
      rejected = false
      begin
        probe.draw(target)
      rescue RuntimeError => error
        raise unless error.message.include?("No captured snapshot")
        rejected = true
      end
      raise "draw accepted a missing snapshot" unless rejected
    ensure
      probe.clear
      [sprite, vp, source, target].each { |resource| resource.dispose unless resource.disposed? }
    end
  end

  def self.run
    raise "snapshot probe unavailable" unless ModLoader::ParallelRenderer.available?
    [:plain, :transform, :wave, :tone, :empty].each { |mode| check_case(mode) }
    check_rejection
    puts "Render snapshot native smoke passed"
    true
  end

  def self.run_worker
    raise "worker API unavailable" unless ModLoader.respond_to?(:parallel_renderer_start)
    [:plain, :transform, :wave, :tone, :empty].each { |mode| check_case(mode, true) }
    # clear joins an unfinished job; a subsequent capture/start must work.
    vp = Viewport.new(0, 0, 32, 32)
    bitmap = Bitmap.new(32, 32)
    begin
      Graphics.update
      3.times do
        ModLoader::ParallelRenderer.capture(vp)
        ModLoader::ParallelRenderer.start(bitmap, 10000)
        ModLoader::ParallelRenderer.clear
        raise "clear retained worker" unless ModLoader::ParallelRenderer.status.include?('"worker_pending":false')
      end
    ensure
      ModLoader::ParallelRenderer.clear
      bitmap.dispose
      vp.dispose
    end
    puts "Render snapshot worker smoke passed"
    true
  end

  def self.run_queue
    probe = ModLoader::ParallelRenderer
    resources = []
    begin
      vp = Viewport.new(0, 0, 32, 32)
      source = Bitmap.new(16, 16)
      sprite = Sprite.new(vp)
      sprite.bitmap = source
      template, result, reference = Bitmap.new(32, 32), Bitmap.new(32, 32), Bitmap.new(32, 32)
      resources.concat([vp, source, sprite, template, result, reference])
      Graphics.update
      probe.clear
      expected = []
      thread_id = nil
      frame_id = nil
      collect = lambda do
        probe.collect(result)
        raise 'FIFO frame pixels differ' unless pixels(result) == expected.shift
        status = probe.status
        current_thread = status[/"last_worker_thread":(\d+)/, 1].to_i
        current_frame = status[/"last_frame":(\d+)/, 1].to_i
        raise 'persistent worker changed threads' if thread_id && thread_id != current_thread
        raise 'FIFO frame IDs are not consecutive' if frame_id && current_frame != frame_id + 1
        thread_id, frame_id = current_thread, current_frame
      end
      24.times do |i|
        source.fill_rect(source.rect, Color.new((i * 31) % 255, (i * 17) % 255, 200))
        reference.clear
        probe.reference(vp, reference)
        expected << pixels(reference)
        probe.submit(vp, template, i.even? ? 1000 : 1)
        if expected.size == 2
          rejected = false
          begin
            probe.submit(vp, template)
          rescue RuntimeError => error
            raise unless error.message.include?('queue is full')
            rejected = true
          end
          raise 'third outstanding frame accepted' unless rejected
          collect.call
        end
      end
      collect.call until expected.empty?
      # A failed capture must leave an already accepted frame collectable.
      reference.clear
      probe.reference(vp, reference)
      expected << pixels(reference)
      probe.submit(vp, template, 1000)
      vp.zoom = 1.5
      Graphics.update
      rejected = false
      begin
        probe.submit(vp, template)
      rescue RuntimeError => error
        raise unless error.message.include?('Custom ViewportEffects')
        rejected = true
      end
      raise 'unsupported queued frame accepted' unless rejected
      collect.call
      vp.zoom = 1.0
      Graphics.update
      3.times do
        2.times { probe.submit(vp, template, 1000) }
        probe.clear
        raise 'clear did not drain both frames' unless probe.status.include?('"queue_depth":0')
      end
      probe.submit(vp, template)
      probe.collect(result)
      raise 'clear restarted persistent worker' unless probe.status.include?('"last_worker_thread":' + thread_id.to_s)
      puts "Two-slot FIFO / rejection / clear PASS; persistent worker=#{thread_id}"
      true
    ensure
      probe.clear
      resources.reverse_each { |resource| resource.dispose unless resource.disposed? }
    end
  end

  def self.benchmark_logic
    value = 0
    40000.times { |i| value = (value + i * 3) & 0xffff }
    value
  end

  # Synthetic CPU render/logic throughput, not game FPS or screen presentation.
  def self.benchmark_queue(frames = 40)
    probe = ModLoader::ParallelRenderer
    resources = []
    begin
      vp = Viewport.new(0, 0, 640, 480)
      source = Bitmap.new(128, 128)
      source.fill_rect(source.rect, Color.new(180, 60, 90, 160))
      template, result = Bitmap.new(640, 480), Bitmap.new(640, 480)
      resources.concat([vp, source, template, result])
      80.times do |i|
        sprite = Sprite.new(vp)
        sprite.bitmap = source
        sprite.x, sprite.y = (i * 47) % 512, (i * 31) % 352
        resources << sprite
      end
      vp.tone = Tone.new(12, -8, 15, 0)
      Graphics.update
      probe.reference(vp, result)
      expected = pixels(result)
      runs = []
      [:serial, :queued, :queued, :serial].each do |mode|
        probe.clear
        pending = 0
        started = Time.now
        frames.times do
          if mode == :serial
            result.clear
            probe.capture(vp)
            probe.draw(result)
          else
            probe.submit(vp, template)
            pending += 1
          end
          benchmark_logic
          if mode == :queued && pending == 2
            probe.collect(result)
            pending -= 1
          end
        end
        pending.times { probe.collect(result) }
        wall_ms = (Time.now - started) * 1000.0
        raise 'benchmark final pixels differ' unless pixels(result) == expected
        runs << [mode, wall_ms]
        puts "Queue benchmark #{mode}: #{frames} frames, #{wall_ms.round(3)} ms; #{(wall_ms / frames).round(3)} ms/frame"
      end
      serial = runs.select { |v| v[0] == :serial }.inject(0.0) { |sum, v| sum + v[1] } / 2
      queued = runs.select { |v| v[0] == :queued }.inject(0.0) { |sum, v| sum + v[1] } / 2
      puts "Queue benchmark mean: serial=#{serial.round(3)} ms queued=#{queued.round(3)} ms ratio=#{(serial / queued).round(3)}"
      true
    ensure
      probe.clear
      resources.reverse_each { |resource| resource.dispose unless resource.disposed? }
    end
  end
end
