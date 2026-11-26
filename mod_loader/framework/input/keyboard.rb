#==============================================================================
# ModLoaderKeyboard - standalone virtual-key table owned by ModLoader.
#
# Windows VK codes under ModLoader::Keyboard, namespaced so it never clashes
# with a game's own (top-level) Keyboard module or another mod. Names drop the
# VK_ prefix, so console binds read nicely: bind :V, "win_battle".
#
# Self-contained - no dependency on any external keyboard script. Aliases share
# a code (e.g. ENTER / RETURN). Use NUMx for the top digit row, NUMPADx for the
# keypad.
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModLoaderKeyboard"]
$imported["IDL-ModLoaderKeyboard"] = "1.0"

module ModLoader
  module Keyboard
    # --- control / editing ---
    BACK = BACKSPACE = 0x08
    TAB = 0x09
    ENTER = RETURN = 0x0D
    SHIFT = 0x10
    CTRL = CONTROL = 0x11
    ALT = MENU = 0x12
    PAUSE = 0x13
    CAPS = CAPSLOCK = 0x14
    ESC = ESCAPE = 0x1B
    SPACE = 0x20
    PRIOR = PAGEUP = 0x21
    NEXT = PAGEDOWN = 0x22
    self::END = 0x23
    HOME = 0x24
    LEFT = 0x25
    UP = 0x26
    RIGHT = 0x27
    DOWN = 0x28
    SNAPSHOT = PRINTSCREEN = 0x2C
    INSERT = 0x2D
    DELETE = 0x2E

    # --- top-row digits ---
    NUM0 = 0x30
    NUM1 = 0x31
    NUM2 = 0x32
    NUM3 = 0x33
    NUM4 = 0x34
    NUM5 = 0x35
    NUM6 = 0x36
    NUM7 = 0x37
    NUM8 = 0x38
    NUM9 = 0x39

    # --- letters ---
    A = 0x41
    B = 0x42
    C = 0x43
    D = 0x44
    E = 0x45
    F = 0x46
    G = 0x47
    H = 0x48
    I = 0x49
    J = 0x4A
    K = 0x4B
    L = 0x4C
    M = 0x4D
    N = 0x4E
    O = 0x4F
    P = 0x50
    Q = 0x51
    R = 0x52
    S = 0x53
    T = 0x54
    U = 0x55
    V = 0x56
    W = 0x57
    X = 0x58
    Y = 0x59
    Z = 0x5A

    # --- windows / apps ---
    LWIN = 0x5B
    RWIN = 0x5C
    APPS = 0x5D

    # --- numpad ---
    NUMPAD0 = 0x60
    NUMPAD1 = 0x61
    NUMPAD2 = 0x62
    NUMPAD3 = 0x63
    NUMPAD4 = 0x64
    NUMPAD5 = 0x65
    NUMPAD6 = 0x66
    NUMPAD7 = 0x67
    NUMPAD8 = 0x68
    NUMPAD9 = 0x69
    MULTIPLY = 0x6A
    ADD = 0x6B
    SEPARATOR = 0x6C
    SUBTRACT = 0x6D
    DECIMAL = 0x6E
    DIVIDE = 0x6F

    # --- function keys ---
    F1 = 0x70
    F2 = 0x71
    F3 = 0x72
    F4 = 0x73
    F5 = 0x74
    F6 = 0x75
    F7 = 0x76
    F8 = 0x77
    F9 = 0x78
    F10 = 0x79
    F11 = 0x7A
    F12 = 0x7B
    F13 = 0x7C
    F14 = 0x7D
    F15 = 0x7E
    F16 = 0x7F
    F17 = 0x80
    F18 = 0x81
    F19 = 0x82
    F20 = 0x83
    F21 = 0x84
    F22 = 0x85
    F23 = 0x86
    F24 = 0x87

    # --- locks ---
    NUMLOCK = 0x90
    SCROLL = 0x91

    # --- left / right modifiers ---
    LSHIFT = 0xA0
    RSHIFT = 0xA1
    LCTRL = LCONTROL = 0xA2
    RCTRL = RCONTROL = 0xA3
    LALT = LMENU = 0xA4
    RALT = RMENU = 0xA5

    # --- OEM punctuation (US layout) ---
    SEMICOLON = 0xBA
    PLUS = 0xBB
    COMMA = 0xBC
    MINUS = 0xBD
    PERIOD = 0xBE
    SLASH = 0xBF
    TILDE = 0xC0
    LBRACKET = 0xDB
    BACKSLASH = 0xDC
    RBRACKET = 0xDD
    QUOTE = 0xDE

    # --- reverse lookup: VK code -> a key name (first-defined name wins) ---
    NAMES = constants(false).each_with_object({}) do |c, table|
      table[const_get(c)] ||= c.to_s
    end

    # @return [String, nil] a key name for +code+, or nil if unknown
    def self.name(code)
      NAMES[code]
    end
  end
end

end # not $imported["IDL-ModLoaderKeyboard"]
