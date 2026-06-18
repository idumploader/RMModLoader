#==============================================================================
# ModLoaderNVRAM - persistent key/value store for mods.
#
# A small "non-volatile memory" that survives game restarts (and crashes). Data
# lives in mod_loader/nvram.dat next to the game and is serialized with Marshal,
# so any Ruby object can be stored. Writes are write-through: every []= / delete
# flushes to disk immediately, so a later crash will not lose what you stored.
#
# Usage:
#   ModLoader.nvram[:runs] = (ModLoader.nvram[:runs] || 0) + 1
#   ModLoader.nvram[:last_map] = $game_map.map_id
#   ModLoader.nvram.delete(:runs)
#
# Keys are shared across every mod on this game - prefix your keys (e.g.
# "mymod.flag") to avoid collisions, or keep a sub-hash under one key.
#
# Version gate: ModLoader.version != "2.4"
#==============================================================================

if ModLoader.version != "2.4"

module ModLoader
  # Marshal-backed, write-through key/value store. See file header for usage.
  class NVRAMStore
    def initialize(path)
      @path = path
      @data = load_data
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
      save
    end

    # Flush the whole store to disk. Called automatically by []= / delete /
    # clear; exposed for callers that mutate a stored object in place.
    def save
      File.open(@path, "wb") { |f| Marshal.dump(@data, f) }
      self
    end

    private

    def load_data
      return {} unless File.exist?(@path)
      File.open(@path, "rb") { |f| Marshal.load(f) }
    rescue StandardError => error
      p "[NVRAM] failed to load #{@path} (#{error}) - starting empty"
      {}
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
