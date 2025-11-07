#pragma once
#include "RMGlobal.hpp"

#include <GLFW/glfw3.h>

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
		static constexpr int bind_escape = 4;
		static constexpr int bind_insert = 5; // or numpad 0
		static constexpr int bind_shift = 6;
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

		static constexpr int down_symbol_index = 2;
		static constexpr int left_symbol_index = 4;
		static constexpr int right_symbol_index = 6;
		static constexpr int up_symbol_index = 8;
		static constexpr int a_symbol_index = 11;
		static constexpr int b_symbol_index = 12;
		static constexpr int c_symbol_index = 13;
		static constexpr int x_symbol_index = 14;
		static constexpr int y_symbol_index = 15;
		static constexpr int z_symbol_index = 16;
		static constexpr int l_symbol_index = 17;
		static constexpr int r_symbol_index = 18;
		static constexpr int shift_symbol_index = 21;
		static constexpr int ctrl_symbol_index = 22;
		static constexpr int alt_symbol_index = 23;
		static constexpr int f5_symbol_index = 25;
		static constexpr int f6_symbol_index = 26;
		static constexpr int f7_symbol_index = 27;
		static constexpr int f8_symbol_index = 28;
		static constexpr int f9_symbol_index = 29;
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

	// hook for enabling gamepad
	struct RxInputControlChangeHook : RxInput {
		static RxInput* (__thiscall RxInput::* orig_update_keys)();

		static float gamepad_deadzone;
		static bool gamepad_x_inverted;
		static bool gamepad_y_inverted;

		void process_gamepad_inputs();

		RxInput* __thiscall update_keys_hook();

		static bool gamepad_pressed(const GLFWgamepadstate& gamepad_state, int key);
		static bool gamepad_axed(const GLFWgamepadstate& gamepad_state, int axis, bool negative);

		static RubyValue __cdecl mod_loader_gamepad_set_deadzone(RubyValue module, RubyValue deadzone_value);
		static RubyValue __cdecl mod_loader_gamepad_bind(RubyValue module, RubyValue button_value, RubyValue button_action_value);
		static RubyValue __cdecl mod_loader_gamepad_set_invert_x(RubyValue module, RubyValue invert_x_value);
		static RubyValue __cdecl mod_loader_gamepad_set_invert_y(RubyValue module, RubyValue invert_y_value);
	};
	
	extern void apply_controls_change();
}