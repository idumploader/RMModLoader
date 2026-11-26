# CONDITIONS/ORDER: load after System Options (1800), if installed, when RPG::BGM/BGS.play,
# Audio play/stop/fade and SceneManager.run are already defined. Default ON.
# Control: Mod menu -> Display -> Advanced -> Optimizations -> Music replay; saved in loader NVRAM.
# Cache matches name, raw volume, pitch and the current system volume setting.
# It is runtime-only, shared by BGM/BGS requests and not written to game saves.
# Repeated default RPG BGM/BGS requests keep playing
# the same sound. Explicit positions (including play(0)) always reach the engine.
# Direct Audio calls, stop/fade, ME and scene-loop reset invalidate the cache.
# Rollback: MusicReplayOptimization.enabled = false
# Force a default replay when required: MusicReplayOptimization.clear(:bgm/:bgs)
$imported ||= {}
unless $imported['IDL-MusicReplayOptimization']
  $imported['IDL-MusicReplayOptimization'] = '1.0'

  module MusicReplayOptimization
    Entry = Struct.new(:name, :volume, :pitch, :system_volume, :result)
    class << self
      attr_reader :enabled, :skipped_bgm, :skipped_bgs

      def enabled=(value)
        clear
        @enabled = !!value
      end

      def clear(channel = nil)
        @bgm = nil if channel.nil? || channel == :bgm
        @bgs = nil if channel.nil? || channel == :bgs
      end

      def system_volume(channel)
        # Game_System#volume belongs to the optional System Options script,
        # not stock RGSS. Without it, only the track's own volume applies.
        $game_system && $game_system.respond_to?(:volume) ? $game_system.volume(channel) : nil
      end

      def repeated?(channel, track)
        return false unless @enabled
        entry = channel == :bgm ? @bgm : @bgs
        return false unless entry && entry.name == track.name &&
          entry.volume.eql?(track.volume) && entry.pitch.eql?(track.pitch) &&
          entry.system_volume.eql?(system_volume(channel))
        if channel == :bgm
          @skipped_bgm += 1
        else
          @skipped_bgs += 1
        end
        true
      end

      def result(channel)
        (channel == :bgm ? @bgm : @bgs).result
      end

      def remember(channel, track, result)
        return unless @enabled
        entry = Entry.new(track.name.dup, track.volume, track.pitch,
                          system_volume(channel), result)
        channel == :bgm ? @bgm = entry : @bgs = entry
      end
    end
    @skipped_bgm = @skipped_bgs = 0
    self.enabled = true
  end

  # Invalidate below RPG wrappers, so direct Audio calls also force the next
  # request through. Never suppress direct Audio calls or their return values.
  singleton = class << Audio; self; end
  [:bgm_play, :bgm_stop, :bgm_fade, :bgs_play, :bgs_stop, :bgs_fade,
   :me_play, :me_stop, :me_fade].each do |name|
    next unless Audio.respond_to?(name)
    channel = name.to_s.start_with?('bgs') ? :bgs : :bgm
    singleton.class_eval <<-RUBY, __FILE__, __LINE__ + 1
      alias music_replay_original_#{name} #{name}
      def #{name}(*args, &block)
        MusicReplayOptimization.clear(:#{channel})
        music_replay_original_#{name}(*args, &block)
      end
    RUBY
  end

  [[:bgm, RPG::BGM], [:bgs, RPG::BGS]].each do |channel, klass|
    klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
      alias music_replay_original_play play
      def play(*args)
        if args.empty? && MusicReplayOptimization.repeated?(:#{channel}, self)
          return MusicReplayOptimization.result(:#{channel})
        end
        result = music_replay_original_play(*args)
        MusicReplayOptimization.remember(:#{channel}, self, result) if args.empty?
        result
      end
    RUBY
  end

  # F12 and an uncaught exception must not leave a cache describing old audio.
  module SceneManager
    class << self
      alias music_replay_original_run run
      def run
        MusicReplayOptimization.clear
        music_replay_original_run
      ensure
        MusicReplayOptimization.clear
      end
    end
  end
end
