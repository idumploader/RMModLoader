#include "IntegratedHooks.hpp"
#include "ControlsChangeHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"

#include <GLFW/glfw3.h>

#undef min
#undef max

namespace rm_modloader {

	RxInput*(__thiscall RxInput::* ExtendedControlSet::orig_update_keys)() = nullptr;

	std::array<int, 30> ExtendedControlSet::gamepad_binds;
	std::array<BYTE, 256> ExtendedControlSet::current_keyboard_state;
	std::array<BYTE, 256> ExtendedControlSet::prev_keyboard_state;

	std::chrono::high_resolution_clock::duration ExtendedControlSet::repeat_delta = std::chrono::milliseconds(50);
	std::chrono::high_resolution_clock::duration ExtendedControlSet::repeat_hang_time = std::chrono::milliseconds(250);
	std::array<std::chrono::high_resolution_clock::time_point, 256> ExtendedControlSet::last_pressed_time;
	std::array<std::chrono::high_resolution_clock::time_point, 256> ExtendedControlSet::last_repeat_time;
	std::array<bool, 256> ExtendedControlSet::last_requested_repeat;

	float ExtendedControlSet::gamepad_deadzone = 0.4f;
	bool ExtendedControlSet::gamepad_x_inverted = false;
	bool ExtendedControlSet::gamepad_y_inverted = true;

	RxInput* __thiscall ExtendedControlSet::update_keys_hook() {
		(this->*orig_update_keys)();
		process_extended_control_set();
		process_gamepad_inputs();
		return this;
	}

	void ExtendedControlSet::process_extended_control_set() {
		prev_keyboard_state = current_keyboard_state;
		if (!GetKeyboardState(current_keyboard_state.data())) {
			// error
		}

		auto time_now = std::chrono::high_resolution_clock::now();
		for (size_t i = 0; i < current_keyboard_state.size(); ++i) {
			last_pressed_time[i] = (current_keyboard_state[i] & 0x80) && !(prev_keyboard_state[i] & 0x80) ?
				time_now : last_pressed_time[i];

			bool should_reset_repeat = time_now - last_repeat_time[i] >= repeat_delta && last_requested_repeat[i] && (current_keyboard_state[i] & 0x80);
			last_repeat_time[i] = should_reset_repeat ? time_now : last_pressed_time[i];
			last_requested_repeat[i] = false;
		}
	}

	void ExtendedControlSet::process_gamepad_inputs() {
		GLFWgamepadstate gamepad_state;
		bool is_connected = glfwGetGamepadState(0, &gamepad_state);
		if (!is_connected) {
			return;
		}

		immediate_current_keys[keys::key_down]  |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_Y, true) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_DOWN);
		immediate_current_keys[keys::key_left]  |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_X, true) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_LEFT);
		immediate_current_keys[keys::key_up]    |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_Y, false) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_UP);
		immediate_current_keys[keys::key_right] |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_X, false) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_RIGHT);

		immediate_current_keys[key_binds[keys::bind_z]] |= static_cast<BYTE>(gamepad_pressed(gamepad_state, gamepad_binds[keys::z_symbol_index]));
		immediate_current_keys[key_binds[keys::bind_x]] |= static_cast<BYTE>(gamepad_pressed(gamepad_state, gamepad_binds[keys::x_symbol_index]));
		immediate_current_keys[key_binds[keys::bind_shift]] |= static_cast<BYTE>(gamepad_pressed(gamepad_state, gamepad_binds[keys::shift_symbol_index]));
	}

	bool ExtendedControlSet::gamepad_pressed(const GLFWgamepadstate& gamepad_state, int key) {
		return gamepad_state.buttons[key] == GLFW_TRUE;
	}

	bool ExtendedControlSet::gamepad_axed(const GLFWgamepadstate& gamepad_state, int axis, bool negative) {
		bool inverted = (axis == GLFW_GAMEPAD_AXIS_LEFT_X && gamepad_x_inverted) || (axis == GLFW_GAMEPAD_AXIS_LEFT_Y && gamepad_y_inverted);
		return (negative ^ inverted) ? gamepad_state.axes[axis] < -gamepad_deadzone : gamepad_state.axes[axis] > gamepad_deadzone;
	}

	bool ExtendedControlSet::is_key_pressed(int key) {
		return (current_keyboard_state[key] & 0x80) && !(prev_keyboard_state[key] & 0x80);
	}

	bool ExtendedControlSet::is_key_repeated(int key) {
		bool is_pressed = (current_keyboard_state[key] & 0x80);
		auto time_now = std::chrono::high_resolution_clock::now();

		if (is_key_pressed(key)
			|| is_pressed && time_now - last_pressed_time[key] >= repeat_hang_time && time_now - last_repeat_time[key] >= repeat_delta) {
			last_requested_repeat[key] = true;
			return ruby_true;
		}
		return ruby_false;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_input_trigger(RubyValue module, RubyValue key_value) {
		int key = rb_parse_int(key_value);
		if (key >= 0xFF) {
			return ruby_false;
		}

		return is_key_pressed(key) ? ruby_true : ruby_false;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_input_repeat(RubyValue module, RubyValue key_value) {
		int key = rb_parse_int(key_value);
		if (key >= 0xFF) {
			return ruby_false;
		}

		return is_key_repeated(key) ? ruby_true : ruby_false;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_map_to_char(RubyValue module, RubyValue key_value) {
		int key = rb_parse_int(key_value);
		if (key >= 0xFF) {
			return ruby_false;
		}

		WORD symb;
		BOOL ret = ToAscii(key, 0, current_keyboard_state.data(), &symb, 0);
		return ret ? rb_make_number(symb & 0xFF) : ruby_nil;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_gamepad_set_deadzone(RubyValue module, RubyValue deadzone_value) {
		int deadzone = rb_parse_int(deadzone_value);

		gamepad_deadzone = std::min(deadzone, 255) / 255.f;

		return ruby_true;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_gamepad_bind(RubyValue module, RubyValue button_value, RubyValue button_action_value) {
		int button = rb_parse_int(button_value);
		if (button < 0 || button >= GLFW_GAMEPAD_BUTTON_LAST) {
			return ruby_false;
		}
		int key_index = get_rb_key_symbol_index(button_action_value);
		if (key_index == 0) {
			return ruby_false;
		}

		gamepad_binds[key_index] = button;

		return ruby_true;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_gamepad_set_invert_x(RubyValue module, RubyValue invert_x_value) {
		if (invert_x_value != ruby_true && invert_x_value != ruby_false) {
			return ruby_false;
		}
		gamepad_x_inverted = invert_x_value == ruby_true;
		return ruby_true;
	}

	RubyValue __cdecl ExtendedControlSet::mod_loader_gamepad_set_invert_y(RubyValue module, RubyValue invert_y_value) {
		if (invert_y_value != ruby_true && invert_y_value != ruby_false) {
			return ruby_false;
		}
		gamepad_y_inverted = invert_y_value == ruby_true;
		return ruby_true;
	}

	void apply_integrated_hooks() {
		// input_update_keys is also hooked by HRFixHooks; the hook chain composes
		// both, so we no longer re-point input_update_keys at our detour by hand.
		mod_loader->hook_method(input_update_keys, &ExtendedControlSet::update_keys_hook, &ExtendedControlSet::orig_update_keys);

		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("gamepad_deadzone=", &ExtendedControlSet::mod_loader_gamepad_set_deadzone);
			mod_loader->register_ruby_method("gamepad_bind",      &ExtendedControlSet::mod_loader_gamepad_bind);
			mod_loader->register_ruby_method("gamepad_invert_x=", &ExtendedControlSet::mod_loader_gamepad_set_invert_x);
			mod_loader->register_ruby_method("gamepad_invert_y=", &ExtendedControlSet::mod_loader_gamepad_set_invert_y);

			mod_loader->register_ruby_method("input_trigger?",    &ExtendedControlSet::mod_loader_input_trigger);
			mod_loader->register_ruby_method("input_repeat?",     &ExtendedControlSet::mod_loader_input_repeat);
			mod_loader->register_ruby_method("map_char",          &ExtendedControlSet::mod_loader_map_to_char);
		});
	}
}