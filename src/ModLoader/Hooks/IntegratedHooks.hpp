#pragma once
#include "../RMClasses.hpp"
#include "../RMGlobal.hpp"

#include <chrono>
#include <array>

struct GLFWgamepadstate;

namespace rm_modloader {
	/**
	 * This hook provides gamepad support, input processing with VKKeys
	 * and character code mapping to ASCII
	 */
	struct ExtendedControlSet : RxInput {
		static RxInput*(__thiscall RxInput::* orig_update_keys)();

		static std::array<int, 30> gamepad_binds;
		static std::array<BYTE, 256> current_keyboard_state;
		static std::array<BYTE, 256> prev_keyboard_state;

		static std::chrono::high_resolution_clock::duration repeat_delta;
		static std::chrono::high_resolution_clock::duration repeat_hang_time;
		static std::array<std::chrono::high_resolution_clock::time_point, 256> last_pressed_time;
		static std::array<std::chrono::high_resolution_clock::time_point, 256> last_repeat_time;
		static std::array<bool, 256> last_requested_repeat;

		static float gamepad_deadzone;
		static bool gamepad_x_inverted;
		static bool gamepad_y_inverted;

		RxInput* __thiscall update_keys_hook();

		void process_extended_control_set();
		void process_gamepad_inputs();

		static bool gamepad_pressed(const GLFWgamepadstate& gamepad_state, int key);
		static bool gamepad_axed(const GLFWgamepadstate& gamepad_state, int axis, bool negative);

		static bool is_key_pressed(int key);
		static bool is_key_repeated(int key);

		static RubyValue __cdecl mod_loader_input_trigger(RubyValue module, RubyValue key_value);
		static RubyValue __cdecl mod_loader_input_repeat(RubyValue module, RubyValue key_value);
		static RubyValue __cdecl mod_loader_map_to_char(RubyValue module, RubyValue key_value);

		static RubyValue __cdecl mod_loader_gamepad_set_deadzone(RubyValue module, RubyValue deadzone_value);
		static RubyValue __cdecl mod_loader_gamepad_bind(RubyValue module, RubyValue button_value, RubyValue button_action_value);
		static RubyValue __cdecl mod_loader_gamepad_set_invert_x(RubyValue module, RubyValue invert_x_value);
		static RubyValue __cdecl mod_loader_gamepad_set_invert_y(RubyValue module, RubyValue invert_y_value);
	};

	extern void apply_integrated_hooks();
}