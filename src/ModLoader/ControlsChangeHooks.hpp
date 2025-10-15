#pragma once
#include "RMGlobal.hpp"

namespace rm_modloader {

	namespace keys {
		static constexpr int key_down = 2;
		static constexpr int key_left = 4;
		static constexpr int key_right = 6;
		static constexpr int key_up = 8;
		static constexpr int key_page_up = 17;
		static constexpr int key_page_down = 18;
		static constexpr int key_shift = 21;
		static constexpr int key_control = 22;
		static constexpr int key_menu = 23;
		static constexpr int key_f5 = 25;
		static constexpr int key_f6 = 26;
		static constexpr int key_f7 = 27;
		static constexpr int key_f8 = 28;
		static constexpr int key_f9 = 29;

		static constexpr int bind_space = 2;
		static constexpr int bind_return = 3;
		static constexpr int bind_insert = 4; // or numpad 0
		static constexpr int bind_shift = 5;
		static constexpr int bind_z = 7;
		static constexpr int bind_x = 8;
		static constexpr int bind_c = 9;
		static constexpr int bind_v = 10;
		static constexpr int bind_b = 11;
		static constexpr int bind_a = 12;
		static constexpr int bind_s = 13;
		static constexpr int bind_d = 14;
		static constexpr int bind_q = 15;
		static constexpr int bind_w = 16;
		static constexpr int bind_mod_control = 15;
	}

	enum class ControlsChangerKey {
		Down,
		Left,
		Right,
		Up,
		A,
		B,
		C,
		D,
		Q,
		S,
		V,
		W,
		X,
		Z,
		Max = Z
	};

	struct ControlsChangeHooks {
		static decltype(&GetKeyState) orig_GetKeyState;

		static SHORT __stdcall get_key_state_hook(int virt_key);

		static RubyValue __cdecl mod_loader_hook_key(RubyValue module, RubyValue orig_virt_key, RubyValue virt_key);
	};
	
	extern void apply_controls_change();
}