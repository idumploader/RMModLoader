#==============================================================================
# MobMovementToggle
#------------------------------------------------------------------------------
# Adds a persistent ModMenu switch for autonomous map-event movement.
#
# This wrapper loads after the game's final Game_Event implementation.
# It covers both movement sources used by BS2:
#   * the engine's random / approach / custom autonomous movement (@move_type);
#   * the symbol-enemy AI from 怪物行为设定※ (@symbol_encount).
#
# Forced move routes are intentionally left alone: Game_Event#update_stop does
# not call update_self_movement while @move_route_forcing is true.
#==============================================================================

$imported ||= {}
if not $imported["IDL-MobMovementToggle"]
$imported["IDL-MobMovementToggle"] = "1.0"

module ModLoader
module MobMovementToggle
  KEY = "mob_autonomous_movement"

  class << self
    def enabled?
      return true unless defined?(ModLoader::ModMenu)
      values = ModLoader::ModMenu.section
      values.key?(KEY) ? !!values[KEY] : true
    end
  end
end
end

if defined?(Game_Event)
  class Game_Event < Game_Character
    alias_method :mob_toggle_orig_update_self_movement, :update_self_movement

    def update_self_movement
      return if mob_toggle_autonomous_mob? &&
                !ModLoader::MobMovementToggle.enabled?
      mob_toggle_orig_update_self_movement
    end

    # Stock autonomous movers use @move_type 1..3.  BS2 symbol enemies are the
    # exception: their custom AI deliberately keeps @move_type at 0.
    def mob_toggle_autonomous_mob?
      (!!@symbol_encount) || (!@move_type.nil? && @move_type != 0)
    end
  end
end

if defined?(ModLoader::ModMenu)
  ModLoader::ModMenu.header("Gameplay",
    :category => "Debug")
  ModLoader::ModMenu.toggle(
    "Автономное движение мобов",
    :category => "Debug",
    :key => ModLoader::MobMovementToggle::KEY,
    :default => true,
    :on_text => "ON",
    :off_text => "OFF"
  )
end

puts "[MobMovementToggle] registered - ModMenu > Debug"

end # not $imported["IDL-MobMovementToggle"]
