#==============================================================================
# EventInteractionToggle
#------------------------------------------------------------------------------
# Adds a persistent ModMenu switch next to MobMovementToggle.  When disabled,
# map events stay visible and can still animate/move, but they cannot start an
# interaction and no map/parallel interpreter advances.  This makes developer
# map inspection and MapSnapshotter captures safe from battles, transfers,
# autoruns, pickups, and cutscenes.
#==============================================================================

$imported ||= {}
if not $imported["IDL-EventInteractionToggle"]
$imported["IDL-EventInteractionToggle"] = "1.0"

module ModLoader
module EventInteractionToggle
  KEY = "map_event_interactions"

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
    alias_method :interaction_toggle_orig_start, :start

    def start
      return unless ModLoader::EventInteractionToggle.enabled?
      interaction_toggle_orig_start
    end

    if method_defined?(:update_parallel)
      alias_method :interaction_toggle_orig_update_parallel, :update_parallel

      def update_parallel
        return unless ModLoader::EventInteractionToggle.enabled?
        interaction_toggle_orig_update_parallel
      end
    end
  end
end

if defined?(Game_Map)
  class Game_Map
    alias_method :interaction_toggle_orig_update_interpreter, :update_interpreter

    def update_interpreter
      return unless ModLoader::EventInteractionToggle.enabled?
      interaction_toggle_orig_update_interpreter
    end
  end
end

if defined?(Game_CommonEvent)
  class Game_CommonEvent
    alias_method :interaction_toggle_orig_update, :update

    def update
      return unless ModLoader::EventInteractionToggle.enabled?
      interaction_toggle_orig_update
    end
  end
end

if defined?(ModLoader::ModMenu)
  ModLoader::ModMenu.toggle(
    "Взаимодействия с событиями",
    :category => "Debug",
    :key => ModLoader::EventInteractionToggle::KEY,
    :default => true,
    :on_text => "ON",
    :off_text => "OFF"
  )
end

puts "[EventInteractionToggle] registered - ModMenu > Debug"

end # not $imported["IDL-EventInteractionToggle"]
