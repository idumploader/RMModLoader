#==============================================================================
# ControlsChanger — applies the custom keyboard and gamepad bindings (WASD
# movement, remapped confirm/cancel/page keys, gamepad deadzone/axes/buttons).
#
# Calls ModLoader.hook_key / gamepad_* to install the remaps; edit the bindings
# block at the top to taste.
#
# Dependencies: ModLoader::Keyboard (7), ModLoader::Gamepad (8), ModLoader
#               gamepad API.
# Config gate:  ModLoader.controls_change_enabled
#==============================================================================

$imported ||= {}
if not $imported["IDL-ControlsChange"]
$imported["IDL-ControlsChange"] = "1.0"

if ModLoader.controls_change_enabled

# --- CONTROLS SETTINGS ---
ModLoader.hook_key(ModLoader::Keyboard::DOWN, ModLoader::Keyboard::S)  # down
ModLoader.hook_key(ModLoader::Keyboard::LEFT, ModLoader::Keyboard::A)  # left
ModLoader.hook_key(ModLoader::Keyboard::RIGHT, ModLoader::Keyboard::D)  # right
ModLoader.hook_key(ModLoader::Keyboard::UP, ModLoader::Keyboard::W)    # up
ModLoader.hook_key(ModLoader::Keyboard::Z, ModLoader::Keyboard::SPACE)  # confirm
ModLoader.hook_key(ModLoader::Keyboard::X, ModLoader::Keyboard::Q)    # cancel
# --- CONTROLS SETTINGS ---

ModLoader.hook_key(ModLoader::Keyboard::S, ModLoader::Keyboard::DOWN)  # page down
# ModLoader.hook_key(ModLoader::Keyboard::D, ModLoader::Keyboard::LEFT)
# ModLoader.hook_key(ModLoader::Keyboard::A, ModLoader::Keyboard::RIGHT)
ModLoader.hook_key(ModLoader::Keyboard::Q, ModLoader::Keyboard::UP)    # page up
ModLoader.hook_key(ModLoader::Keyboard::W, ModLoader::Keyboard::X)
ModLoader.hook_key(ModLoader::Keyboard::D, ModLoader::Keyboard::RIGHT)
ModLoader.hook_key(ModLoader::Keyboard::A, ModLoader::Keyboard::LEFT)

# --- GAMEPAD CONTROLS SETTINGS ---
ModLoader.gamepad_deadzone = 100
ModLoader.gamepad_invert_x = false
ModLoader.gamepad_invert_y = true

ModLoader.gamepad_bind(ModLoader::Gamepad::A, :Z)
ModLoader.gamepad_bind(ModLoader::Gamepad::B, :X)
ModLoader.gamepad_bind(ModLoader::Gamepad::RIGHT_BUMPER, :SHIFT)
# --- GAMEPAD CONTROLS SETTINGS ---

puts "[ControlsChanger] custom key & gamepad bindings applied"

end # ModLoader.controls_change_enabled

end # not $imported["IDL-ControlsChange"]