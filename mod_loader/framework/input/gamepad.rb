#==============================================================================
# ModLoaderGamepad - standalone gamepad button table owned by ModLoader.
#
# Button ids (XInput order) under ModLoader::Gamepad, namespaced so it never
# clashes with a game's own constants or another mod. Pass these to
# ModLoader.gamepad_bind(ModLoader::Gamepad::A, :Z).
#
# Self-contained - no dependency on any external controls script.
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModLoaderGamepad"]
$imported["IDL-ModLoaderGamepad"] = "1.0"

module ModLoader
  module Gamepad
    A = 0
    B = 1
    X = 2
    Y = 3
    LEFT_BUMPER = 4
    RIGHT_BUMPER = 5
    BACK = 6
    START = 7
    GUIDE = 8
    LEFT_THUMB = 9
    RIGHT_THUMB = 10
    DPAD_UP = 11
    DPAD_RIGHT = 12
    DPAD_DOWN = 13
    DPAD_LEFT = 14

    # --- reverse lookup: button id -> a button name (first-defined name wins) ---
    NAMES = constants(false).each_with_object({}) do |c, table|
      table[const_get(c)] ||= c.to_s
    end

    # @return [String, nil] a button name for +id+, or nil if unknown
    def self.name(id)
      NAMES[id]
    end
  end
end

end # not $imported["IDL-ModLoaderGamepad"]
