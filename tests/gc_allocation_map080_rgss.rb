module GCAllocationBench
  def self.measure(label, iterations)
    GC.start
    before = ObjectSpace.count_objects
    gc_before = GC.count
    GC.disable
    started = Time.now
    begin
      iterations.times { yield }
      wall_ms = (Time.now - started) * 1000.0
      after = ObjectSpace.count_objects
      raise 'GC occurred while disabled' unless GC.count == gc_before
    ensure
      GC.enable
    end
    types = [:T_STRING, :T_ARRAY, :T_HASH, :T_OBJECT, :T_DATA,
             :T_NODE, :T_REGEXP, :T_STRUCT, :T_MATCH]
    counts = types.map { |type| "#{type}=#{after[type].to_i-before[type].to_i}" }.join(' ')
    File.open('map080.log', 'ab') do |file|
      file.write("GC_ALLOC #{label} iterations=#{iterations} wall_ms=#{wall_ms} #{counts}\n")
    end
  end

  def self.measure_gc(label, enabled, scene)
    MapUpdateOptimizations.object_character = enabled
    GC.start
    before = GC.count
    durations = []
    gc_steps = 0
    1200.times do
      gc_before = GC.count
      started = Time.now
      scene.update
      durations << (Time.now - started) * 1000.0
      gc_steps += 1 if GC.count > gc_before
    end
    counts = GC.count - before
    sorted = durations.sort
    File.open('map080.log', 'ab') do |file|
      file.write("GC_PHASE #{label} iterations=1200 gc=#{counts} gc_steps=#{gc_steps} " +
                 "median_ms=#{sorted[600]} p99_ms=#{sorted[1187]} " +
                 "max_ms=#{sorted[-1]} over40=#{durations.count { |ms| ms > 40.0 }}\n")
    end
  end

  def self.run(scene)
    spriteset = scene.instance_variable_get(:@spriteset)
    characters = spriteset.instance_variable_get(:@character_sprites)
    raise 'object_character optimization not installed' unless MapUpdateOptimizations.object_character_installed
    characters.each do |sprite|
      character = sprite.character
      raise 'object_character mismatch' unless character.object_character? == character.mapopt_original_object_character?
    end
    [[0, ''], [0, '!Object'], [0, '$Big'], [0, 'тест'], [1, '']].each do |tile_id, name|
      character = Game_CharacterBase.allocate
      character.instance_variable_set(:@tile_id, tile_id)
      character.instance_variable_set(:@character_name, name)
      raise 'object_character edge mismatch' unless character.object_character? == character.mapopt_original_object_character?
    end
    MapUpdateOptimizations.object_character = false
    measure('scene_original_object_character', 60) { scene.update }
    MapUpdateOptimizations.object_character = true
    measure('scene_update', 60) { scene.update }
    measure('map_update', 60) { $game_map.update(true) }
    measure('player_update', 60) { $game_player.update }
    measure('spriteset_update', 60) { spriteset.update }
    measure('character_loop', 60) { characters.each { |sprite| sprite.update } }
    [:update_bitmap, :update_src_rect, :update_position, :update_other,
     :update_balloon, :setup_new_effect].each do |method|
      measure("character_#{method}", 60) do
        characters.each { |sprite| sprite.send(method) }
      end
    end
    base_update = Sprite_Base.instance_method(:update)
    measure('character_base_update', 60) do
      characters.each { |sprite| base_update.bind(sprite).call }
    end
    measure('character_screen_xy', 60) do
      characters.each { |sprite| sprite.character.screen_x; sprite.character.screen_y }
    end
    measure('character_screen_z', 60) do
      characters.each { |sprite| sprite.character.screen_z }
    end
    measure('sprite_xy_get', 60) do
      characters.each { |sprite| sprite.x; sprite.y }
    end
    measure('sprite_xyz_set', 60) do
      characters.each { |sprite| sprite.x = 1; sprite.y = 1; sprite.z = 1 }
    end
    measure('move_animation', 60) do
      characters.each { |sprite| sprite.move_animation(0, 0) }
    end
    measure_gc('original', false, scene)
    measure_gc('fixed', true, scene)
  end
end
