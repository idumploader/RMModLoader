#==============================================================================
# MapSnapshotter - stitch a full-map screenshot by panning the map camera and
# snapshotting ONLY the map viewport (no HUD/windows), one screen at a time.
#
# How it works:
#   * grabs Spriteset_Map's @viewport1 (tilemap + parallax + character sprites -
#     the map layer only; HUD windows live on other viewports, so they're out).
#   * hides the player (+ followers) and fully freezes Game_Player#update while a
#     capture runs, so no input / event triggers fire and the sprite is gone.
#   * pans $game_map.set_display_pos across a screen-sized grid, letting the
#     tilemap settle a few frames, then <viewport>.snap_to_bitmap ->
#     ModLoader.save_as_bmp to mod_loader/mapshots/map<ID>/tile_NNN.bmp.
#   * writes manifest.json with each tile's pixel offset for the Python stitcher
#     (stitch_mapshots.py).
#
# Trigger: ModMenu -> "Debug" tab -> "Snapshot this map". The action only queues a
# request; the capture runs once you close the menu and Scene_Map resumes. You
# can also call MapSnapshotter.start from the executor console.
#==============================================================================

if Object.const_defined?(:ModLoader)

$imported ||= {}
unless $imported["IDL-MapSnapshotter"]
$imported["IDL-MapSnapshotter"] = "1.0"

module MapSnapshotter
  # --- config ---------------------------------------------------------------
  SETTLE_FRAMES   = 2       # frames to let the tilemap scroll to each camera
                            # position before snapping (snap renders live state)
  OUTPUT_ROOT     = "mod_loader/mapshots"
  NEUTRALIZE_TONE = false   # true -> temporarily clear the map viewport tone
                            #         (night/dark tints) for a flat, clean map

  # Whichever the deployed ModLoader.dll registered (name changed across builds).
  SAVE_METHOD = [:save_as_bmp, :dump_as_bmp].find { |m| ModLoader.respond_to?(m) }

  class << self
    def active?;  @active;  end
    def pending?; @pending; end

    # Queue a capture. Safe to call from ModMenu / console; the real work starts
    # on the next Scene_Map#update once the map scene is actually running.
    def start
      if @active
        note("A map snapshot is already running.")
        return false
      end
      unless SAVE_METHOD
        note("ModLoader has no save_as_bmp/dump_as_bmp - can't save. Old DLL?")
        return false
      end
      @pending = true
      true
    end

    # Called every frame from the Scene_Map#update hook.
    def on_map_update(scene)
      if @active
        step
      elsif @pending
        return if menu_open?     # wait until the ModMenu overlay is closed
        @pending = false
        begin_capture(scene)
      end
    end

    def menu_open?
      defined?(ModLoader::ModMenu) &&
        ModLoader::ModMenu.respond_to?(:active?) && ModLoader::ModMenu.active?
    end

    # ----------------------------------------------------------------------
    private

    def begin_capture(scene)
      spriteset = scene.instance_variable_get(:@spriteset)
      viewport  = spriteset && spriteset.instance_variable_get(:@viewport1)
      unless viewport
        note("No map viewport found - are we on the field map?")
        return
      end
      @viewport = viewport
      @map_id = $game_map.map_id
      @sw     = Graphics.width
      @sh     = Graphics.height
      @dir    = "#{OUTPUT_ROOT}/map%03d" % @map_id
      mkdir_p(@dir)

      build_targets
      hide_player
      apply_tone_override if NEUTRALIZE_TONE

      @manifest = []
      @idx      = 0
      @wait     = SETTLE_FRAMES
      @active   = true
      ModLoader.log("[MapSnap] start map #{@map_id}: #{@targets.size} tiles " \
                    "(#{@map_w}x#{@map_h} tiles)\n") if ModLoader.respond_to?(:log)
    end

    def step
      if @idx >= @targets.size
        finish
        return
      end

      tx, ty = @targets[@idx]
      $game_map.set_display_pos(tx, ty)   # re-assert every frame (holds camera)

      if @wait > 0
        @wait -= 1
        return
      end

      # Settled: the tilemap has scrolled to (tx,ty). Snapshot just the map layer.
      bmp  = snap_map_only
      file = "tile_%03d.bmp" % @idx
      ok   = ModLoader.send(SAVE_METHOD, bmp, "#{@dir}/#{file}")
      w, h = bmp.width, bmp.height
      bmp.dispose
      unless ok
        note("save_as_bmp failed on #{file}; aborting.")
        finish
        return
      end

      @manifest << { :file => file, :x => tx * 32, :y => ty * 32, :w => w, :h => h }
      @idx  += 1
      @wait  = SETTLE_FRAMES
    end

    # Snapshot ONLY the map layer, HUD/menu excluded. snap_to_bitmap is stock
    # RGSS and always grabs the whole screen, so we borrow Zeus' z-mask trick:
    # drop a fullscreen black sprite just under a huge z, lift the map viewport
    # ABOVE it, snap, then restore. Everything below the black cover (HUD sprites
    # on the default viewport, menu windows, weather on viewport2/3) is masked
    # out; only the lifted map viewport shows.
    def snap_map_only
      vp    = @viewport
      z_vp  = vp.z
      cover = Sprite.new
      cover.bitmap = Bitmap.new(1, 1)
      cover.bitmap.set_pixel(0, 0, Color.new(0, 0, 0))
      cover.zoom_x = Graphics.width
      cover.zoom_y = Graphics.height
      cover.z = 0x0FFF_FFFF
      vp.z = 0x2FFF_FFFF          # lift the whole map viewport above the cover
      bmp = Graphics.snap_to_bitmap
      vp.z = z_vp
      cover.bitmap.dispose
      cover.dispose
      bmp
    end

    def finish
      write_manifest
      restore_tone_override if NEUTRALIZE_TONE
      restore_player
      $game_player.center($game_player.x, $game_player.y)  # camera back to hero
      count = @manifest ? @manifest.size : 0
      @active   = false
      @viewport = nil
      @manifest = nil
      ModLoader.log("[MapSnap] done map #{@map_id}: #{count} tiles -> #{@dir}\n") \
        if ModLoader.respond_to?(:log)
      note("Map #{@map_id} snapshot done: #{count} tiles in\n#{@dir}\n\n" \
           "Run:  python stitch_mapshots.py \"<game>/#{@dir}\"")
    end

    # ---- camera grid ------------------------------------------------------
    def build_targets
      stx = $game_map.screen_tile_x
      sty = $game_map.screen_tile_y
      @map_w = $game_map.width
      @map_h = $game_map.height
      xs = axis(@map_w, stx)
      ys = axis(@map_h, sty)
      @targets = []
      ys.each { |ty| xs.each { |tx| @targets << [tx, ty] } }
    end

    # Top-left tile offsets covering the whole axis in screen-sized steps; the
    # final step is clamped to the last full screen so nothing is missed.
    def axis(map_tiles, screen_tiles)
      out = []
      v = 0
      while v < map_tiles - screen_tiles
        out << v
        v += screen_tiles
      end
      out << [map_tiles - screen_tiles, 0].max
      out.uniq
    end

    # ---- hide / restore player -------------------------------------------
    def hide_player
      pl = $game_player
      @pl_transparent = pl.transparent
      pl.transparent = true
      @foll_state = []
      pl.followers.each do |f|
        @foll_state << [f, f.transparent]
        f.transparent = true
      end
    end

    def restore_player
      $game_player.transparent = @pl_transparent if @pl_transparent != nil
      (@foll_state || []).each { |f, t| f.transparent = t }
      @pl_transparent = nil
      @foll_state = nil
    end

    # ---- optional tone flatten -------------------------------------------
    def apply_tone_override
      return unless @viewport.respond_to?(:tone)
      t = @viewport.tone
      @saved_tone = Tone.new(t.red, t.green, t.blue, t.gray)
      @viewport.tone.set(0, 0, 0, 0)
    end

    def restore_tone_override
      return unless @saved_tone && @viewport && @viewport.respond_to?(:tone)
      @viewport.tone.set(@saved_tone.red, @saved_tone.green,
                         @saved_tone.blue, @saved_tone.gray)
      @saved_tone = nil
    end

    # ---- io ---------------------------------------------------------------
    def mkdir_p(path)
      part = ""
      path.split(/[\/\\]/).each do |d|
        part = part.empty? ? d : File.join(part, d)
        Dir.mkdir(part) unless Dir.exist?(part)
      end
    end

    def write_manifest
      tiles = (@manifest || []).map { |t|
        %Q(  {"file":"#{t[:file]}","x":#{t[:x]},"y":#{t[:y]},"w":#{t[:w]},"h":#{t[:h]}})
      }.join(",\n")
      json = %Q({\n) +
             %Q(  "map_id": #{@map_id},\n) +
             %Q(  "screen_w": #{@sw},\n) +
             %Q(  "screen_h": #{@sh},\n) +
             %Q(  "map_px_w": #{@map_w * 32},\n) +
             %Q(  "map_px_h": #{@map_h * 32},\n) +
             %Q(  "tiles": [\n#{tiles}\n  ]\n) +
             %Q(}\n)
      File.open("#{@dir}/manifest.json", "w") { |f| f.write(json) }
    end

    def note(msg)
      puts "[MapSnap] #{msg}"
      msgbox(msg) if Object.respond_to?(:msgbox)
    end
  end
end

# --- freeze the player while a capture runs (no input, no event triggers, and
#     with transparent=true the sprite is gone from the viewport snapshot) -----
class Game_Player
  unless method_defined?(:msnap_orig_update)
    alias msnap_orig_update update
    def update
      return if MapSnapshotter.active?
      msnap_orig_update
    end
  end
end

# --- drive the capture state machine from the field scene --------------------
class Scene_Map
  unless method_defined?(:msnap_orig_update)
    alias msnap_orig_update update
    def update
      msnap_orig_update
      MapSnapshotter.on_map_update(self)
    end
  end
end

# --- ModMenu entry -----------------------------------------------------------
if defined?(ModLoader::ModMenu)
  M = ModLoader::ModMenu
  M.header("Screenshot", :category => "Debug")
  # :close_after closes the menu, so the capture runs on a clean map (the gate in
  # on_map_update waits for ModMenu.active? == false before starting).
  M.action("Snapshot this map", :category => "Debug", :close_after => true) do
    MapSnapshotter.start
  end
  puts "[MapSnapshotter] registered - ModMenu > Debug > Snapshot this map"
end

end # $imported guard
end # const_defined?(:ModLoader)
