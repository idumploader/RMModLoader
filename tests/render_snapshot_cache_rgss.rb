# Run in RGSS after render_snapshot_rgss_smoke.rb, using the matching native DLL.
module RenderSnapshotCache
  def self.stat(probe, name)
    probe.status[/"#{name}":([0-9.eE+-]+)/, 1].to_f
  end

  def self.equal!(a, b, label)
    raise "#{label}: pixels differ" unless ModLoader.parallel_renderer_pixels_equal(a, b)
  end

  def self.run
    probe = ModLoader::ParallelRenderer
    resources = []
    begin
      vp = Viewport.new(0, 0, 64, 64)
      source, stamp = Bitmap.new(64, 64), Bitmap.new(16, 16)
      sprite = Sprite.new(vp)
      sprite.bitmap = source
      template, result, before, after = Array.new(4) { Bitmap.new(64, 64) }
      resources.concat([vp, source, stamp, sprite, template, result, before, after])
      stamp.fill_rect(stamp.rect, Color.new(20, 230, 90, 255))
      writers = [
        [:blt, proc { source.blt(3, 4, stamp, stamp.rect) }],
        [:stretch_blt, proc { source.stretch_blt(Rect.new(2, 3, 35, 30), stamp, stamp.rect) }],
        [:fill_rect, proc { source.fill_rect(1, 2, 20, 25, Color.new(10, 220, 30)) }],
        [:gradient_fill_rect, proc { source.gradient_fill_rect(source.rect, Color.new(0, 255, 0), Color.new(0, 0, 255)) }],
        [:clear, proc { source.clear }],
        [:clear_rect, proc { source.clear_rect(2, 3, 20, 30) }],
        [:set_pixel, proc { source.set_pixel(5, 7, Color.new(1, 250, 150)) }],
        [:hue_change, proc { source.hue_change(95) }],
        [:blur, proc { source.blur }],
        [:radial_blur, proc { source.radial_blur(30, 4) }],
        [:draw_text, proc { source.draw_text(source.rect, 'Cache') }]
      ]
      [1, 2].each do |mode|
        writers.each do |name, mutate|
          probe.clear
          probe.optimization(mode)
          source.fill_rect(source.rect, Color.new(180, 30, 60, 220))
          source.fill_rect(0, 0, 30, 30, Color.new(30, 70, 240, 255))
          Graphics.update
          before.clear
          probe.reference(vp, before)
          probe.submit(vp, template, 1000)
          mutate.call
          after.clear
          probe.reference(vp, after)
          probe.submit(vp, template)
          raise "#{name}: modification did not invalidate cache" unless stat(probe, 'cache_misses') == 2
          probe.collect(result)
          equal!(result, before, "#{name} old version mode #{mode}")
          probe.collect(result)
          equal!(result, after, "#{name} new version mode #{mode}")
          probe.submit(vp, template)
          probe.collect(result)
          raise "#{name}: unchanged bitmap missed cache" unless stat(probe, 'cache_hits') == 1
          equal!(result, after, "#{name} cached mode #{mode}")
        end
        puts "Bitmap writers mode=#{mode}: all 11 invalidation/old-version/cache-hit checks PASS"
      end
      # Both pending frames share an immutable version; originals may disappear.
      probe.submit(vp, template, 1000)
      probe.submit(vp, template)
      source.dispose
      sprite.dispose
      GC.start
      raise 'dispose retained cache entry' unless stat(probe, 'cache_bytes') == 0
      2.times { probe.collect(result); equal!(result, after, 'shared version after dispose') }
      # Native destruction must evict old keys even when addresses are reused.
      40.times do |i|
        bitmap = Bitmap.new(64, 64)
        item = Sprite.new(vp)
        begin
          bitmap.fill_rect(bitmap.rect, Color.new(i * 5, 210 - i * 3, 40))
          item.bitmap = bitmap
          Graphics.update
          before.clear
          probe.reference(vp, before)
          probe.submit(vp, template)
          probe.collect(result)
          equal!(result, before, 'recreated Bitmap')
        ensure
          item.dispose
          bitmap.dispose
        end
        raise 'destroyed Bitmap remained cached' unless stat(probe, 'cache_bytes') == 0
      end
      puts 'Shared version disposal / repeated Bitmap recreation PASS'
      # Changes to the template, pooled target dimensions and mode switching.
      fresh = Bitmap.new(64, 64)
      item = Sprite.new(vp)
      small = Bitmap.new(32, 32)
      small_result = Bitmap.new(32, 32)
      small_reference = Bitmap.new(32, 32)
      resources.concat([fresh, item, small, small_result, small_reference])
      item.bitmap = fresh
      fresh.fill_rect(fresh.rect, Color.new(230, 50, 70, 120))
      Graphics.update
      [[template, result, before], [small, small_result, small_reference], [template, result, before]].each_with_index do |targets, index|
        bg, output, expected = targets
        color = Color.new(10 + index * 30, 20, 50, 130)
        bg.fill_rect(bg.rect, color)
        expected.fill_rect(expected.rect, color)
        probe.reference(vp, expected)
        probe.submit(vp, bg)
        begin
          probe.optimization(0)
          raise 'mode switch accepted pending frame'
        rescue RuntimeError => error
          raise unless error.message.include?('Collect or clear pending frames')
        end
        bg.clear # submitted background must remain independent
        probe.collect(output)
        equal!(output, expected, 'pooled template/dimensions')
      end
      # Explicit notification for pixel writers outside standard RGSS APIs.
      misses = stat(probe, 'cache_misses')
      probe.invalidate(fresh)
      probe.submit(vp, template)
      probe.collect(result)
      raise 'explicit invalidation ignored' unless stat(probe, 'cache_misses') == misses + 1
      puts 'Pooled template changes / dimensions / mode guard / explicit invalidation PASS'
      true
    ensure
      probe.clear
      probe.optimization(0)
      resources.reverse_each { |r| r.dispose unless r.disposed? }
    end
  end

  # Includes source mutations, capture, synthetic Ruby logic and collection.
  # Excludes presentation and reference pixel checks. Source size stays constant
  # across resolutions, so larger output buffers are measured independently.
  def self.benchmark(frames = 24)
    probe = ModLoader::ParallelRenderer
    original_size = [Graphics.width, Graphics.height]
    modes = [[:serial, 0], [:serial_cache, 1], [:queue, 0], [:cache, 1], [:pool, 2]]
    rows = []
    begin
      # HRFix needs process startup with the desired width/height. Earlier runs
      # changed only output Bitmap sizes; resize_screen did not apply to Graphics.
      [original_size].each do |w, h|
        [0, 10, 100].each do |percent|
          resources = []
          begin
            Graphics.resize_screen(w, h)
            raise 'resolution not applied' unless [Graphics.width, Graphics.height] == [w, h]
            vp = Viewport.new(0, 0, w, h)
            template, result, reference = Array.new(3) { Bitmap.new(w, h) }
            stamp = Bitmap.new(64, 64)
            sources = Array.new(20) { Bitmap.new(256, 256) }
            resources.concat([vp, template, result, reference, stamp] + sources)
            stamp.fill_rect(stamp.rect, Color.new(20, 230, 90, 200))
            40.times do |i|
              sprite = Sprite.new(vp)
              sprite.bitmap = sources[i % sources.size]
              sprite.x, sprite.y = (i * 137) % (w - 256), (i * 97) % (h - 256)
              resources << sprite
            end
            vp.tone = Tone.new(12, -8, 15, 0)
            (modes + modes.reverse).each do |label, mode|
              serial = label == :serial || label == :serial_cache
              probe.clear
              probe.optimization(mode)
              sources.each_with_index { |b, i| b.fill_rect(b.rect, Color.new(100 + i * 5, 60, 90, 160)) }
              Graphics.update
              # Untimed warmup: thread startup, cache and both target slots.
              2.times { probe.submit(vp, template) }
              2.times { probe.collect(result) }
              bytes_before = stat(probe, 'source_copied_bytes')
              hits_before = stat(probe, 'cache_hits')
              reuse_before = stat(probe, 'target_reuses')
              pending = 0
              submitted_ms = waited_ms = collected_ms = rendered_ms = 0.0
              started = Time.now
              frames.times do |frame|
                (sources.size * percent / 100).times do |j|
                  sources[(j + frame * 2) % sources.size].blt((frame * 7) % 192, (frame * 11) % 192, stamp, stamp.rect)
                end
                if serial
                  result.clear
                  probe.capture(vp)
                  probe.draw(result)
                else
                  probe.submit(vp, template)
                  pending += 1
                end
                RenderSnapshotSmoke.benchmark_logic
                if !serial && pending == 2
                  probe.collect(result)
                  pending -= 1
                end
                status = probe.status
                if serial
                  submitted_ms += status[/"capture_ms":([0-9.eE+-]+)/, 1].to_f
                  rendered_ms += status[/"draw_ms":([0-9.eE+-]+)/, 1].to_f
                else
                  submitted_ms += status[/"last_submit_ms":([0-9.eE+-]+)/, 1].to_f
                  if frame > 0
                    waited_ms += status[/"last_wait_ms":([0-9.eE+-]+)/, 1].to_f
                    collected_ms += status[/"last_collect_ms":([0-9.eE+-]+)/, 1].to_f
                    rendered_ms += status[/"last_worker_ms":([0-9.eE+-]+)/, 1].to_f
                  end
                end
              end
              pending.times do
                probe.collect(result)
                status = probe.status
                waited_ms += status[/"last_wait_ms":([0-9.eE+-]+)/, 1].to_f
                collected_ms += status[/"last_collect_ms":([0-9.eE+-]+)/, 1].to_f
                rendered_ms += status[/"last_worker_ms":([0-9.eE+-]+)/, 1].to_f
              end
              wall = (Time.now - started) * 1000.0
              copied = stat(probe, 'source_copied_bytes') - bytes_before
              hits = stat(probe, 'cache_hits') - hits_before
              reuses = stat(probe, 'target_reuses') - reuse_before
              reference.clear
              probe.reference(vp, reference)
              equal!(result, reference, "benchmark #{w}x#{h}/#{percent}/#{label}")
              row = [w, h, percent, label, frames, wall, copied, hits, reuses, submitted_ms, waited_ms, collected_ms, rendered_ms]
              rows << row
              puts 'CACHE_BENCH ' + row.map { |v| v.is_a?(Float) ? v.round(3) : v }.join(',')
            end
          ensure
            probe.clear
            probe.optimization(0)
            resources.reverse_each { |r| r.dispose unless r.disposed? }
          end
        end
      end
      puts 'Cache benchmark all final frames pixel-exact PASS'
      rows
    ensure
      Graphics.resize_screen(*original_size)
    end
  end
end
