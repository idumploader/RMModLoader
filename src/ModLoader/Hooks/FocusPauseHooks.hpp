#pragma once

namespace rm_modloader {
	extern void apply_focus_pause_hooks();

	// Real foreground state of the game window, for input consumers that bypass the
	// WinAPI input hooks (e.g. ExtendedControlSet reads the gamepad via GLFW). Works
	// whether or not the focus-pause feature is enabled.
	extern bool is_window_focused();
}
