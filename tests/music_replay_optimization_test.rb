require 'minitest/autorun'

module Audio
  class << self
    attr_accessor :calls, :fail
    [:bgm_play, :bgm_stop, :bgm_fade, :bgs_play, :bgs_stop, :bgs_fade,
     :me_play, :me_stop, :me_fade].each do |name|
      define_method(name) do |*args|
        raise 'audio failure' if fail
        calls << [name, args]
        :audio_result
      end
    end
  end
end
module RPG
  class AudioFile
    attr_accessor :name, :volume, :pitch
    def initialize(name = '', volume = 100, pitch = 100)
      @name, @volume, @pitch = name, volume, pitch
    end
  end
  [[:bgm, 'BGM'], [:bgs, 'BGS']].each do |channel, name|
    klass = Class.new(AudioFile)
    const_set(name, klass)
    klass.class_eval <<-RUBY
      @@last = nil
      def self.last; @@last; end
      def play(pos = 0)
        if @name.empty?
          Audio.#{channel}_stop
          @@last = self.class.new
        else
          volume = @volume
          volume *= $game_system.volume(:#{channel}) * 0.01 if $game_system && $game_system.respond_to?(:volume)
          Audio.#{channel}_play('Audio/#{name}/' + @name, volume, @pitch, pos)
          @@last = self.clone
        end
      end
    RUBY
  end
end
module SceneManager
  def self.run; raise 'reset'; end
end
load File.expand_path('../mod_loader/scripts/1810 - MusicReplayOptimization.rb', __dir__)

class MusicReplayOptimizationTest < Minitest::Test
  def test_stock_game_system_without_volume_plays_and_deduplicates
    $game_system = Object.new
    [RPG::BGM, RPG::BGS].each do |klass|
      track = klass.new('stock', 65, 90)
      track.play
      count = Audio.calls.size
      assert_nil MusicReplayOptimization.system_volume(klass == RPG::BGM ? :bgm : :bgs)
      assert_equal 65, Audio.calls.last[1][1]
      track.play
      assert_equal count, Audio.calls.size
    end
  end

  def setup
    Audio.calls, Audio.fail = [], false
    $game_system = Object.new
    def $game_system.volume(channel); (@volumes ||= {:bgm=>100,:bgs=>100})[channel]; end
    def $game_system.set_volume(channel, value); volume(channel); @volumes[channel] = value; end
    MusicReplayOptimization.enabled = true
  end

  def test_duplicate_bgm_and_bgs_preserve_last_and_return_value
    [RPG::BGM, RPG::BGS].each do |klass|
      first = klass.new('track', 30, 70)
      result = first.play
      last = klass.last
      count = Audio.calls.size
      duplicate = klass.new('track', 30, 70)
      assert_same result, duplicate.play
      assert_same last, klass.last
      assert_equal count, Audio.calls.size
    end
  end

  def test_track_volume_pitch_and_options_changes_reach_engine
    track = RPG::BGS.new('Storm', 30, 70)
    track.play
    track.name = 'other'; track.play
    track.volume = 50; track.play
    track.pitch = 80; track.play
    $game_system.set_volume(:bgs, 40); track.play
    assert_equal 5, Audio.calls.size
    assert_equal [:bgs_play, ['Audio/BGS/other', 20.0, 80, 0]], Audio.calls.last
    assert_equal 50, RPG::BGS.last.volume
  end

  def test_mutated_track_name_does_not_mutate_cached_name
    name = +'Storm'
    track = RPG::BGS.new(name)
    track.play
    name.replace('Rain')
    track.play
    assert_equal 2, Audio.calls.size
  end

  def test_explicit_zero_and_nonzero_positions_always_forward
    track = RPG::BGM.new('track')
    track.play
    track.play(0); track.play(123); track.play(123)
    assert_equal [0, 0, 123, 123], Audio.calls.map { |call| call[1].last }
    track.play
    assert_equal 5, Audio.calls.size
  end

  def test_direct_audio_stop_fade_and_me_invalidate_cache
    [:bgm_play, :bgm_stop, :bgm_fade, :me_play, :me_stop, :me_fade].each do |method|
      track = RPG::BGM.new('track')
      track.play
      Audio.send(method, *({:bgm_play=>['direct'],:bgm_fade=>[300],:me_play=>['effect'],:me_fade=>[300]}[method] || []))
      count = Audio.calls.size
      track.play
      assert_equal count + 1, Audio.calls.size, method.to_s
    end
    track = RPG::BGS.new('Storm'); track.play
    Audio.bgs_fade(300); track.play
    Audio.bgs_stop; track.play
    assert_equal :bgs_play, Audio.calls.last[0]
  end

  def test_channels_are_independent_and_empty_track_stops_once
    bgm = RPG::BGM.new('track'); bgm.play
    RPG::BGS.new('Storm').play
    count = Audio.calls.size
    bgm.play
    assert_equal count, Audio.calls.size
    empty = RPG::BGS.new
    empty.play; empty.play
    assert_equal 1, Audio.calls.count { |call| call[0] == :bgs_stop }
    assert_equal '', RPG::BGS.last.name
  end

  def test_audio_exception_and_scene_reset_do_not_retain_cache
    track = RPG::BGM.new('track'); track.play
    Audio.fail = true
    assert_raises(RuntimeError) { Audio.bgm_stop }
    Audio.fail = false
    count = Audio.calls.size
    track.play
    assert_equal count + 1, Audio.calls.size
    assert_raises(RuntimeError) { SceneManager.run }
    count = Audio.calls.size
    track.play
    assert_equal count + 1, Audio.calls.size
  end

  def test_rollback_and_reenable_force_playback
    track = RPG::BGM.new('track'); track.play
    MusicReplayOptimization.enabled = false
    track.play; track.play
    assert_equal 3, Audio.calls.size
    MusicReplayOptimization.enabled = true
    track.play
    assert_equal 4, Audio.calls.size
    track.play
    assert_equal 4, Audio.calls.size
  end
end
