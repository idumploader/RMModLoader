# Shared controls for map updates, battle portraits, music playback and glyphs.
# Load after ModMenu/NVRAM; optimization implementations themselves load later.
# All defaults ON. Missing implementations are disabled in the menu.
# Saved choices are restored at scene-loop entry (including F12); no frame poll.
$imported ||= {}
unless $imported['IDL-ModLoaderOptimizations']
  $imported['IDL-ModLoaderOptimizations'] = '1.0'
  module ModLoader
    module Optimizations
      KEYS = [:map_updates, :event_refresh, :battle_portraits, :music_replay, :glyph_cache]
      MAP_FLAGS = [:position, :aura, :autorun, :object_character]
      class << self
        def settings; ModLoader.nvram.section(:optimizations); end

        def available?(key)
          case key
          when :map_updates; !!defined?(MapUpdateOptimizations)
          when :event_refresh; !!defined?(MapRefreshOptimization) && MapRefreshOptimization.installed?
          when :music_replay; !!defined?(MusicReplayOptimization)
          when :battle_portraits; !!defined?(BattlePortraitCacheFix) && BattlePortraitCacheFix.installed?
          when :glyph_cache; ModLoader.respond_to?(:glyph_cache_enable) && ModLoader.respond_to?(:glyph_cache_status)
          else; false
          end
        end

        def enabled?(key)
          return false unless available?(key)
          case key
          when :map_updates; MAP_FLAGS.all? { |flag| MapUpdateOptimizations.send(flag) }
          when :event_refresh; MapRefreshOptimization.enabled
          when :music_replay; MusicReplayOptimization.enabled
          when :battle_portraits; BattlePortraitCacheFix.enabled
          when :glyph_cache; ModLoader.glyph_cache_status[/"enabled"\s*:\s*(true|false)/, 1] == 'true'
          end
        end

        def apply(key, value)
          return false unless available?(key)
          case key
          when :map_updates
            MAP_FLAGS.each { |flag| MapUpdateOptimizations.send("#{flag}=", value) }
            MapUpdateOptimizations.invalidate_autoruns
          when :event_refresh; MapRefreshOptimization.enabled = value
          when :music_replay; MusicReplayOptimization.enabled = value
          when :battle_portraits; BattlePortraitCacheFix.enabled = value
          when :glyph_cache; return ModLoader.glyph_cache_enable(value)
          end
          true
        end

        def set(key, value)
          return false unless available?(key)
          previous = settings[key]
          begin
            settings[key] = !!value
            settings.commit
          rescue StandardError => error
            settings[key] = previous
            puts "[Optimizations] could not save: #{error.message}"
            return false
          end
          apply(key, !!value)
        end

        def restore
          KEYS.each do |key|
            saved = settings[key]
            apply(key, saved == false ? false : true)
          end
        end
      end
    end

    def Optimizations.register_menu(menu)
      menu.header('Optimizations')
      menu.toggle('Map updates', :id => :map_updates,
        :description => 'Reduces the work needed to update the map and characters. May improve performance in busy locations. Applies immediately and is saved.',
        :enabled => proc { Optimizations.available?(:map_updates) },
        :get => proc { Optimizations.enabled?(:map_updates) },
        :set => proc { |v| Optimizations.set(:map_updates, v) })
      menu.toggle('Event refresh', :id => :event_refresh,
        :description => 'Avoids unnecessary checks of map events. May reduce slowdown in event-heavy locations. Applies immediately and is saved.',
        :enabled => proc { Optimizations.available?(:event_refresh) },
        :get => proc { Optimizations.enabled?(:event_refresh) },
        :set => proc { |v| Optimizations.set(:event_refresh, v) })
      menu.toggle('Battle portraits', :id => :battle_portraits,
        :description => 'Speeds up repeated drawing of battle portraits without changing their appearance. Applies from the next draw and is saved.',
        :enabled => proc { Optimizations.available?(:battle_portraits) },
        :get => proc { Optimizations.enabled?(:battle_portraits) },
        :set => proc { |v| Optimizations.set(:battle_portraits, v) })
      menu.toggle('Music replay', :id => :music_replay,
        :description => 'Avoids unnecessary restarts of music and background sounds that are already playing. Track changes and fading still work normally. Applies immediately and is saved.',
        :enabled => proc { Optimizations.available?(:music_replay) },
        :get => proc { Optimizations.enabled?(:music_replay) },
        :set => proc { |v| Optimizations.set(:music_replay, v) })
      menu.toggle('Glyph cache', :id => :glyph_cache,
        :description => 'Speeds up repeated text drawing without changing how it looks. Useful in menus and dialogue. Applies immediately and is saved.',
        :enabled => proc { Optimizations.available?(:glyph_cache) },
        :get => proc { Optimizations.enabled?(:glyph_cache) },
        :set => proc { |v| Optimizations.set(:glyph_cache, v) })
    end
  end

  module SceneManager
    class << self
      alias optimizations_original_run run
      def run
        ModLoader::Optimizations.restore
        optimizations_original_run
      end
    end
  end
end
