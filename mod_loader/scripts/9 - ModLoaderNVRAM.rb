#==============================================================================
# ModLoaderNVRAM - persistent key/value store for mods.
#
# A small "non-volatile memory" that survives game restarts (and crashes). Data
# lives in mod_loader/nvram.dat next to the game and is serialized with Marshal,
# so any Ruby object can be stored.
#
# Two ways to use it:
#
#   * Write-through values - for flags, counters, single settings. Every []= /
#     delete flushes to disk immediately, so a crash never loses them:
#       ModLoader.nvram[:runs] = (ModLoader.nvram[:runs] || 0) + 1
#       ModLoader.nvram[:last_map] = $game_map.map_id
#
#   * Sections - a defaults-aware working copy for a group of related options.
#     Edits stay in memory until #commit writes the whole section back in one
#     go. The section is memoized, so every caller shares the same working copy:
#       opts = ModLoader.nvram.section(:sys_volume, :bgm => 100, :sfx => 100)
#       opts[:bgm] = 80          # in memory only
#       opts.commit              # one write-through, on "apply"/scene exit
#
# Keys are shared across every mod on this game - prefix your keys (e.g.
# "mymod.flag") or group them in a section to avoid collisions.
#
# Version gate: ModLoader.version != "2.4"
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModLoaderNVRAM"]
$imported["IDL-ModLoaderNVRAM"] = "1.0"

if ModLoader.version != "2.4"

module ModLoader
  # Marshal-backed, write-through key/value store. See file header for usage.
  class NVRAMStore
    def initialize(path)
      @path = path
      @data = load_data
      @sections = {}
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      @data[key] = value
      save
      value
    end

    def delete(key)
      had = @data.key?(key)
      value = @data.delete(key)
      save if had
      value
    end

    def key?(key)
      @data.key?(key)
    end

    def fetch(key, default = nil)
      @data.fetch(key, default)
    end

    # @return [Hash] a shallow copy - mutating it does NOT persist; use []=
    def to_h
      @data.dup
    end

    def clear
      @data.clear
      @sections.clear
      save
    end

    # Flush the whole store to disk. Called automatically by []= / delete /
    # clear; exposed for callers that mutate a stored object in place.
    def save
      File.open(@path, "wb") { |f| Marshal.dump(@data, f) }
      self
    end

    # A named, defaults-aware working copy (Variant A): mutations stay in memory
    # until #commit. Memoized - every caller with the same +key+ gets the same
    # Section, so they edit one shared working copy. +defaults+ is applied on
    # first access only.
    # @return [Section]
    def section(key, defaults = {})
      @sections[key] ||= Section.new(self, key, defaults)
    end

    # In-memory working copy of one NVRAM key (a Hash), persisted on demand.
    class Section
      def initialize(store, key, defaults)
        @store = store
        @key = key
        # defaults first, persisted values on top; new default keys still appear
        @data = defaults.merge(store[key] || {})
      end

      def [](field)
        @data[field]
      end

      def []=(field, value)
        @data[field] = value
      end

      def fetch(field, *default, &block)
        @data.fetch(field, *default, &block)
      end

      def key?(field)
        @data.key?(field)
      end

      def delete(field)
        @data.delete(field)
      end

      # @return [Hash] a shallow copy of the working state
      def to_h
        @data.dup
      end

      # @return [Boolean] whether the working copy differs from what is on disk
      def dirty?
        @data != (@store[@key] || {})
      end

      # Persist the whole section in one write-through. No-op if unchanged.
      def commit
        @store[@key] = @data.dup if dirty?
        self
      end
      alias save commit

      # Discard in-memory edits and reload from disk.
      def reload
        @data = (@store[@key] || {}).dup
        self
      end
    end
  end

  class << self
    # The shared persistent store, lazily loaded from mod_loader/nvram.dat.
    # @return [NVRAMStore]
    def nvram
      @nvram ||= NVRAMStore.new(File.join(data_directory, "nvram.dat"))
    end
  end
end

end # ModLoader.version != "2.4"

end # not $imported["IDL-ModLoaderNVRAM"]
