$imported ||= {}
if not $imported["IDL-ControlsChange"]
$imported["IDL-ControlsChange"] = "1.0"

if ModLoader.controls_change_enabled

# --- CONTROLS SETTINGS ---
ModLoader.hook_key(VKKeys::VK_DOWN, VKKeys::VK_S)	# down
ModLoader.hook_key(VKKeys::VK_LEFT, VKKeys::VK_A)	# left
ModLoader.hook_key(VKKeys::VK_RIGHT, VKKeys::VK_D)	# right
ModLoader.hook_key(VKKeys::VK_UP, VKKeys::VK_W)		# up
ModLoader.hook_key(VKKeys::VK_Z, VKKeys::VK_SPACE)	# confirm
ModLoader.hook_key(VKKeys::VK_X, VKKeys::VK_Q)		# cancel
# --- CONTROLS SETTINGS ---

ModLoader.hook_key(VKKeys::VK_S, VKKeys::VK_DOWN)	# page down
# ModLoader.hook_key(VKKeys::VK_D, VKKeys::VK_LEFT)
# ModLoader.hook_key(VKKeys::VK_A, VKKeys::VK_RIGHT)
ModLoader.hook_key(VKKeys::VK_Q, VKKeys::VK_UP)		# page up
ModLoader.hook_key(VKKeys::VK_W, VKKeys::VK_X)
ModLoader.hook_key(VKKeys::VK_D, VKKeys::VK_RIGHT)
ModLoader.hook_key(VKKeys::VK_A, VKKeys::VK_LEFT)

# --- GAMEPAD CONTROLS SETTINGS ---
ModLoader.gamepad_deadzone = 100
ModLoader.gamepad_invert_x = false
ModLoader.gamepad_invert_y = true

ModLoader.gamepad_bind(GamepadButtons::A, :Z)
ModLoader.gamepad_bind(GamepadButtons::B, :X)
ModLoader.gamepad_bind(GamepadButtons::RIGHT_BUMPER, :SHIFT)
# --- GAMEPAD CONTROLS SETTINGS ---

end # ModLoader.controls_change_enabled

end # not $imported["IDL-ControlsChange"]