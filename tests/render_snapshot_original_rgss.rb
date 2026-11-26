# Native live-tree timing; requires render_snapshot_cache_rgss.rb helpers.
module RenderSnapshotOriginal
  def self.run(frames = 120)
    probe = ModLoader::ParallelRenderer
    original_size = [Graphics.width, Graphics.height]
    # HRFix resolution must be set before process startup. resize_screen alone
    # does not change it on this build. Run a fresh process per resolution.
    sizes = [original_size]
    begin
      (sizes + sizes.reverse).each do |w, h|
        resources = []
        begin
          probe.clear
          probe.optimization(0)
          Graphics.resize_screen(w, h)
          vp = Viewport.new(0, 0, w, h)
          result, reference = Bitmap.new(w, h), Bitmap.new(w, h)
          stamp = Bitmap.new(64, 64)
          sources = Array.new(20) { Bitmap.new(256, 256) }
          resources.concat([vp, result, reference, stamp] + sources)
          sources.each_with_index { |b, i| b.fill_rect(b.rect, Color.new(100 + i * 5, 60, 90, 160)) }
          stamp.fill_rect(stamp.rect, Color.new(20, 230, 90, 200))
          # Same final scene as the previous 24-frame / 10% mutation benchmark.
          24.times do |frame|
            2.times do |j|
              sources[(j + frame * 2) % sources.size].blt((frame * 7) % 192, (frame * 11) % 192, stamp, stamp.rect)
            end
          end
          40.times do |i|
            sprite = Sprite.new(vp)
            sprite.bitmap = sources[i % sources.size]
            sprite.x, sprite.y = (i * 137) % (w - 256), (i * 97) % (h - 256)
            resources << sprite
          end
          vp.tone = Tone.new(12, -8, 15, 0)
          Graphics.update
          raise 'resolution not applied' unless [Graphics.width, Graphics.height] == [w, h]
          ok = ModLoader.parallel_renderer_original_benchmark(vp, result, frames)
          raise probe.status unless ok
          status = probe.status
          row = [w, h, frames] + %w[original_clear_ms original_draw_ms original_total_ms].map do |key|
            status[/"#{key}":([0-9.eE+-]+)/, 1].to_f
          end
          raise 'live benchmark unexpectedly captured sources' unless RenderSnapshotCache.stat(probe, 'source_copied_bytes') == 0
          probe.reference(vp, reference)
          RenderSnapshotCache.equal!(result, reference, 'original benchmark')
          puts 'ORIGINAL_BENCH ' + row.join(',')
        ensure
          probe.clear
          resources.reverse_each { |r| r.dispose unless r.disposed? }
        end
      end
      puts 'Original live render: both runs pixel-exact PASS'
    ensure
      Graphics.resize_screen(*original_size)
    end
  end
end
