#==============================================================================
# BSMP Mobs — host-driven moving events (step 4). A "mob" is just a Game_Event
# whose active page moves on its own (random / approach / custom). The host keeps
# simulating them normally and broadcasts their positions (MOB_SYNC, see 1240);
# a guest standing on the host's map turns its own copies into puppets — it stops
# running their autonomous movement and instead glides them to the host's
# positions, reusing the same target+glide interpolation as remote players.
#
# We drive the REAL Game_Event (not a ghost sprite like remote players need): the
# game already draws an event's sprite, and keeping the event means its graphic /
# page / passability stay correct for free — page changes follow from the synced
# world state (self-switches), so only the continuous position needs the wire.
#
# Authority is per-map: mobs are the host's only on the map the host is on
# (BSMP.host_here?). A guest alone on another map simulates its mobs locally —
# there's no one to desync against. Triggers/battles are untouched here (step 6).
#
# Loads after the game's Game_Event so the alias wraps the final version.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Mobs"]
$imported["IDL-BSMP-Mobs"] = "1.0"

if defined?(BSMP)

class Game_Event < Game_Character

  # An event the host positions for everyone: an autonomous mover (active page has
  # random/approach/custom movement) OR a BS2 symbol-encounter enemy. The latter is
  # crucial — symbol enemies move via a custom AI (怪物行为设定) with @move_type 0,
  # so the plain move_type test misses them and they'd run fully locally on guests
  # (own movement, own reaction, own opacity), desynced from the host.
  def bsmp_mover?
    return false if @erased # erased (e.g. defeated) events aren't positioned anymore
    (!@move_type.nil? && @move_type != 0) || @symbol_encount
  end

  # True when this mob's movement is currently the host's to drive: we're a guest
  # and the host is on our map. BSMP.host_here? short-circuits on guest? so the host
  # and single-player pay almost nothing.
  def bsmp_puppet?
    BSMP.host_here? && bsmp_mover?
  end

  # Suppress local autonomous movement while the host drives this mob; its position
  # arrives via MOB_SYNC instead. When the host leaves our map this stops returning
  # early and the event resumes simulating itself.
  alias bsmp_orig_update_self_movement update_self_movement
  def update_self_movement
    return if bsmp_puppet?
    bsmp_orig_update_self_movement
  end

  # Apply an authoritative position (and opacity) from the host: glide for small
  # corrections (the common per-tick case), hard-snap for big jumps (teleport / map
  # seam / first sync). Mirrors Player_Character#network_moveto — leaving @x/@y ahead
  # of @real lets Game_CharacterBase#update glide there and play the walk animation.
  # Opacity comes from the host because update_symbol_opacity is suppressed on the
  # puppet (the host fades the enemy by ITS distance; we mirror that, not recompute).
  def bsmp_apply_sync(x, y, dir, opacity = nil)
    set_direction(dir) if dir && dir != 0
    @opacity = opacity unless opacity.nil?
    if (x - @real_x).abs + (y - @real_y).abs > BSMP::Config::MOB_SNAP_DISTANCE
      moveto(x, y)
    else
      @x = x
      @y = y
    end
  end

  # Suppress the BS2 symbol-encounter AI on a puppet so it doesn't fight the host's
  # sync: reaction (the local "!" / forming against OUR player — the balloon is
  # synced from the host instead) and the distance-based opacity recompute (opacity
  # is synced too). Movement is already suppressed via update_self_movement. Guarded
  # by method_defined? so a non-BS2 game without 怪物行为设定 still loads.
  if method_defined?(:update_symbol_reaction)
    alias_method :bsmp_orig_update_symbol_reaction, :update_symbol_reaction
    def update_symbol_reaction
      return if bsmp_puppet?
      bsmp_orig_update_symbol_reaction
    end
  end

  if method_defined?(:update_symbol_opacity)
    alias_method :bsmp_orig_update_symbol_opacity, :update_symbol_opacity
    def update_symbol_opacity
      return if bsmp_puppet?
      bsmp_orig_update_symbol_opacity
    end
  end

  # Host-authoritative removal: erasing an event (a defeated symbol enemy removes
  # itself via the event's post-battle "Erase Event") is local — not a self-switch —
  # so it never reached guests and the enemy lingered. Broadcast it; the guest erases
  # its copy (Events.on_mob_erase). Only the host emits, so a guest applying the erase
  # doesn't echo.
  alias_method :bsmp_orig_erase, :erase
  def erase
    bsmp_orig_erase
    return if not BSMP.host?
    return if not bsmp_network_running?
    return if not $game_map
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::MOB_ERASE, 0, "#{$game_map.map_id};#{@id}"))
  end

  # --- Co-op-aware AI targeting (host computes; guests are puppets) --------------
  # The monster AI (怪物行为设定) only knows $game_player, so enemies ignored guests.
  # Teach it about everyone: target the NEAREST player among the host and the remote
  # guests on this map. We only override the two choke points — distance_from_player
  # (drives "notice?" + the distance opacity fade) and reaction_movement (the chase) —
  # both guarded by method_defined? so a game without the AI still loads.

  # Nearest player character (local player + remote guests on this map). Uses the
  # stock distance helpers, so it's safe even without the monster-AI script.
  def bsmp_target_player
    nearest = $game_player
    best = distance_x_from($game_player.x).abs + distance_y_from($game_player.y).abs
    if $bsmp_players and $game_map
      $bsmp_players.bsmp_players.each_value do |pl|
        next if pl.map_id != $game_map.map_id
        d = distance_x_from(pl.x).abs + distance_y_from(pl.y).abs
        next if d >= best
        best = d
        nearest = pl
      end
    end
    nearest
  end

  if method_defined?(:distance_from_player)
    alias_method :bsmp_orig_distance_from_player, :distance_from_player
    def distance_from_player
      t = bsmp_target_player
      distance_x_from(t.x).abs + distance_y_from(t.y).abs
    end
  end

  if method_defined?(:reaction_movement)
    alias_method :bsmp_orig_reaction_movement, :reaction_movement
    def reaction_movement
      target = bsmp_target_player
      return bsmp_orig_reaction_movement if target.equal?($game_player) # host nearest: stock behaviour
      @move_speed = @reaction_after_speed
      @move_frequency = @reaction_after_frequency
      if @symbol_away_level && @symbol_away_level != 0 && away?
        move_away_from_character(target)
      else
        move_toward_character(target)
      end
    end
  end

end

# Balloon icons (the enemy "!" notice, "?", "..." etc.) are NOT shown via a single
# hookable path here: BS2's monster AI sets `@balloon_id = ...` directly (an ivar
# write — see "怪物行为设定" start_forming), bypassing both the Show Balloon Icon
# command and the balloon_id= setter. So instead of catching the *write*, the host
# watches the *value*: Scene_Map#bsmp_detect_balloon (1240) broadcasts MOB_BALLOON
# on a 0 -> N rising edge of a mob's balloon_id. The guest sets balloon_id on its
# copy (Events.on_mob_balloon) and Sprite_Character plays it; the sprite zeroes it
# again when the animation ends, so the edge re-arms for the next notice.

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Mobs"]
