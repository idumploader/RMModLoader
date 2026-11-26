#include "ControlsChangeHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"

#include <array>

#undef max
#undef min

namespace rm_modloader {
	decltype(&GetKeyState) ControlsChangeHooks::orig_GetKeyState = nullptr;

	std::array<int, 0x100> controls_changer_binds = { 0 };
	// -1 preserves the game's bindings outside map scenes; bits 0/1 enable arrows/WASD.
	int movement_keys = -1;

	SHORT __stdcall ControlsChangeHooks::get_key_state_hook(int virt_key) {
		if (movement_keys >= 0) {
			int letter = 0;
			switch (virt_key) {
			case VK_LEFT: letter = 'A'; break;
			case VK_RIGHT: letter = 'D'; break;
			case VK_UP: letter = 'W'; break;
			case VK_DOWN: letter = 'S'; break;
			}
			if (letter) {
				SHORT state = 0;
				if (movement_keys & 1) state |= orig_GetKeyState(virt_key);
				if (movement_keys & 2) state |= orig_GetKeyState(letter);
				return state;
			}
		}
		if (virt_key < 0 || virt_key >= static_cast<int>(controls_changer_binds.size()))
			return orig_GetKeyState(virt_key);
		int binded_key = controls_changer_binds[virt_key];
		return orig_GetKeyState(binded_key != 0 ? binded_key : virt_key);
	}

	RubyValue __cdecl ControlsChangeHooks::mod_loader_hook_key(RubyValue module, RubyValue orig_virt_key_val, RubyValue virt_key_val) {
		int orig_virt_key = rb_parse_int(orig_virt_key_val);
		int virt_key = rb_parse_int(virt_key_val);

		if (orig_virt_key < 0 || orig_virt_key > 0xFF || virt_key < 0 || virt_key > 0xFF) {
			return ruby_false;
		}
		controls_changer_binds[orig_virt_key] = virt_key;
		return ruby_true;
	}

	RubyValue __cdecl ControlsChangeHooks::mod_loader_movement_keys(RubyValue module, RubyValue mode) {
		const int value = rb_parse_int(mode);
		if (value < -1 || value > 3) return ruby_false;
		movement_keys = value;
		return ruby_true;
	}

	void apply_controls_change() {
		mod_loader->hook_api_function(L"user32.dll", "GetKeyState", &ControlsChangeHooks::get_key_state_hook, &ControlsChangeHooks::orig_GetKeyState);

		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("hook_key", &ControlsChangeHooks::mod_loader_hook_key);
			mod_loader->register_ruby_method("movement_keys", &ControlsChangeHooks::mod_loader_movement_keys);
		});
	}
}
