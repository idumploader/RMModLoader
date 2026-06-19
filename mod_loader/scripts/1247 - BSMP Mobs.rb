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

  # An autonomous mover: the active page has random (1), approach (2) or custom (3)
  # movement. Static events (move_type 0) are pure map data, identical for everyone,
  # and need no position sync.
  def bsmp_mover?
    !@move_type.nil? && @move_type != 0
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

  # Apply an authoritative position from the host: glide for small corrections (the
  # common per-tick case), hard-snap for big jumps (teleport / map seam / first
  # sync). Mirrors Player_Character#network_moveto — leaving @x/@y ahead of @real
  # lets Game_CharacterBase#update glide there and play the walk animation.
  def bsmp_apply_sync(x, y, dir)
    set_direction(dir) if dir && dir != 0
    if (x - @real_x).abs + (y - @real_y).abs > BSMP::Config::MOB_SNAP_DISTANCE
      moveto(x, y)
    else
      @x = x
      @y = y
    end
  end

end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Mobs"]
