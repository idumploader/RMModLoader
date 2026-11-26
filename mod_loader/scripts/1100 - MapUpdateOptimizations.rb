# Map optimizations for the original BS2/VX Ace scripts (Ruby 1.9-compatible).
# ORDER: load after the game and WdTk scripts, before later sprite wrappers.
# CONDITIONS: position/object-character replacements require known original
# sources; aura requires the StarAura API; refresh dedup requires stock on_change
# and stock/WdTk setters. Unrecognized implementations are left untouched.
# Refresh dedup applies only to identical Integer/Float/boolean/nil writes;
# arrays/strings, changed values, explicit on_change and later hooks still run.
# No event/AI throttling or offscreen culling. OFF calls the original methods.
# Settings: Mod menu -> Display -> Advanced -> Optimizations; applied now and saved in loader NVRAM.
# Runtime flags: MapUpdateOptimizations.position/aura/autorun/object_character;
# MapRefreshOptimization.enabled. All default ON.
# In-place edits of common-event database entries require invalidate_autoruns;
# replacing/resizing the database and changing CommonEvent.trigger invalidate
# automatically. Runtime caches are not included in game saves.

$imported ||= {}
unless $imported["IDL-MapUpdateOptimizations"]
$imported["IDL-MapUpdateOptimizations"] = "1.0"

module MapUpdateOptimizations
  class << self
    attr_accessor :position, :aura, :autorun, :object_character
    attr_reader :position_installed, :object_character_installed

    def invalidate_autoruns
      @database = @autorun_candidates = nil
    end

    def autorun_candidates
      database = $data_common_events
      if !@database.equal?(database) || @database_size != database.size
        # Preserve database order, including priority when multiple switches
        # are enabled. Switch state itself is deliberately never cached.
        @autorun_candidates = database.select { |event| event && event.autorun? }
        @database = database
        @database_size = database.size
      end
      @autorun_candidates
    end

    def install_position
      @position_installed = true
    end

    def install_object_character
      @object_character_installed = true
    end
  end
  self.position = self.aura = self.autorun = self.object_character = true
end

# The stock VX Ace check allocates two Strings for every non-tile character:
# @character_name[0, 1] and the '!' literal. Compare the ASCII prefix byte
# without creating either String. Keep the old method available for rollback.
object_character_source = Game_CharacterBase.instance_method(:object_character?).source_location
if object_character_source && (object_character_source[0] == "{0032}" ||
    File.basename(object_character_source[0]) =~ /\A32 - Game_CharacterBase\.rb\z/)
  class Game_CharacterBase
    alias mapopt_original_object_character? object_character?
    def object_character?
      return mapopt_original_object_character? unless MapUpdateOptimizations.object_character
      @tile_id > 0 || @character_name.getbyte(0) == 33
    end
  end
  MapUpdateOptimizations.install_object_character
end

# Replace only the known VX Ace SP1 wrapper, not an unrelated mod's method.
# Keep screen_x/y/z: they include the game's coordinate and looping-map rules.
if Sprite_Character.method_defined?(:vxace_sp1_update_position)
  position_source = Sprite_Character.instance_method(:update_position).source_location
  if position_source && (position_source[0] == "{0123}" ||
      File.basename(position_source[0]) =~ /\A123 - /)
    class Sprite_Character
      alias mapopt_original_update_position update_position
      def update_position
        return mapopt_original_update_position unless MapUpdateOptimizations.position
        sx = @character.screen_x
        sy = @character.screen_y
        move_animation(sx - x, sy - y)
        self.x = sx
        self.y = sy
        self.z = @character.screen_z
      end
    end
    MapUpdateOptimizations.install_position
  end
end

if Sprite.method_defined?(:star_aura_effects_update)
  class Sprite
    alias mapopt_original_aura_update star_aura_effects_update
    def star_aura_effects_update(target)
      if MapUpdateOptimizations.aura && target &&
          !@star_aura_effect_update && !target.star_aura_effect_update &&
          @star_aura_effect_keys && @star_aura_effect_keys.empty? &&
          @star_aura_effect_sprites && @star_aura_effect_sprites.empty? &&
          target.aura_effect_data.empty?
        return @star_aura_effect_sprites
      end
      mapopt_original_aura_update(target)
    end
  end
end

class Game_Map
  alias mapopt_original_setup_autorun setup_autorun_common_event
  def setup_autorun_common_event
    return mapopt_original_setup_autorun unless MapUpdateOptimizations.autorun
    event = MapUpdateOptimizations.autorun_candidates.find do |candidate|
      $game_switches[candidate.switch_id]
    end
    @interpreter.setup(event.list) if event
    event
  end
end

class RPG::CommonEvent
  alias mapopt_original_trigger_set trigger=
  def trigger=(value)
    result = self.mapopt_original_trigger_set(value)
    MapUpdateOptimizations.invalidate_autoruns
    result
  end
end

end

# Event-page refresh deduplication (keeps its legacy module/import ID).
# Avoid full event-page refreshes for repeated immutable switch/variable writes.
# Keep the original setters so static-ID rules and later hooks still run.
# Explicit on_change and Game_Map.refresh calls remain available to scripts.
# Runtime rollback: MapRefreshOptimization.enabled = false
$imported ||= {}
unless $imported['IDL-MapRefreshOptimization']
  $imported['IDL-MapRefreshOptimization'] = '1.0'

  module MapRefreshOptimization
    class << self
      attr_accessor :enabled

      def installed?
        (defined?(Game_Switches) && Game_Switches.method_defined?(:map_refresh_original_set)) ||
          (defined?(Game_Variables) && Game_Variables.method_defined?(:map_refresh_original_set))
      end

      def immutable?(value)
        value.nil? || value.equal?(true) || value.equal?(false) ||
          value.is_a?(Integer) || value.is_a?(Float)
      end

      def install(klass, number, basename, setter_name = :[]=)
        return unless klass.method_defined?(setter_name) && klass.method_defined?(:on_change)
        setter = klass.instance_method(setter_name).source_location
        change = klass.instance_method(:on_change).source_location
        # Only the stock refresh notifier and stock/WdTk setters are known here.
        return unless change && known_source?(change[0], number, basename)
        return unless setter && (known_source?(setter[0], number, basename) ||
          known_source?(setter[0], 132, nil))
        return if klass.method_defined?(:map_refresh_original_set)
        klass.class_eval do
          alias_method :map_refresh_original_set, setter_name
          alias_method :map_refresh_original_on_change, :on_change

          def map_refresh_set(id, value)
            existed = instance_variable_defined?(:@map_refresh_unchanged_write)
            previous = @map_refresh_unchanged_write
            @map_refresh_unchanged_write = MapRefreshOptimization.enabled &&
              MapRefreshOptimization.immutable?(value) && @data[id].eql?(value)
            map_refresh_original_set(id, value)
          ensure
            if existed
              @map_refresh_unchanged_write = previous
            else
              remove_instance_variable(:@map_refresh_unchanged_write) if
                instance_variable_defined?(:@map_refresh_unchanged_write)
            end
          end

          def on_change
            return true if MapRefreshOptimization.enabled && @map_refresh_unchanged_write
            map_refresh_original_on_change
          end
          alias_method setter_name, :map_refresh_set
        end
      end

      def known_source?(file, number, basename)
        file == ('{%04d}' % number) ||
          (basename && File.basename(file) == "#{number} - #{basename}.rb")
      end
    end
    self.enabled = true
  end

  MapRefreshOptimization.install(Game_Switches, 13, 'Game_Switches') if defined?(Game_Switches)
  MapRefreshOptimization.install(Game_Variables, 14, 'Game_Variables') if defined?(Game_Variables)
end
