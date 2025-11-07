#include "ControlsChangeHooks.hpp"
#include "ModLoader.hpp"
#include "Hook.hpp"

#include <GLFW/glfw3.h>
#include <array>

#undef max
#undef min

namespace rm_modloader {
	decltype(&GetKeyState) ControlsChangeHooks::orig_GetKeyState = nullptr;

	std::array<int, 0xFF> controls_changer_binds = { 0 };

	std::array<int, 30> gamepad_binds = { 0 };

	SHORT __stdcall ControlsChangeHooks::get_key_state_hook(int virt_key) {
		int binded_key = controls_changer_binds[virt_key];
		return orig_GetKeyState(binded_key != 0 ? binded_key : virt_key);
	}

	RubyValue __cdecl ControlsChangeHooks::mod_loader_hook_key(RubyValue module, RubyValue orig_virt_key_val, RubyValue virt_key_val) {
		int orig_virt_key = rb_parse_int(orig_virt_key_val);
		int virt_key = rb_parse_int(virt_key_val);

		if (orig_virt_key > 0xFF) {
			return ruby_false;
		}
		mod_loader->log_info("ControlChanger: hooked {:x} => {:x}\n", orig_virt_key, virt_key);
		controls_changer_binds[orig_virt_key] = virt_key;
		return ruby_true;
	}

	RxInput* (__thiscall RxInput::* RxInputControlChangeHook::orig_update_keys)() = nullptr;

	float RxInputControlChangeHook::gamepad_deadzone = 0.4f;
	bool RxInputControlChangeHook::gamepad_x_inverted = false;
	bool RxInputControlChangeHook::gamepad_y_inverted = true;

	void RxInputControlChangeHook::process_gamepad_inputs() {
		GLFWgamepadstate gamepad_state;
		bool is_connected = glfwGetGamepadState(0, &gamepad_state);
		if (!is_connected) {
			return;
		}

		immediate_current_keys[keys::key_down]  |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_Y, true) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_DOWN);
		immediate_current_keys[keys::key_left]  |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_X, true) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_LEFT);
		immediate_current_keys[keys::key_up]    |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_Y, false) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_UP);
		immediate_current_keys[keys::key_right] |= gamepad_axed(gamepad_state, GLFW_GAMEPAD_AXIS_LEFT_X, false) || gamepad_pressed(gamepad_state, GLFW_GAMEPAD_BUTTON_DPAD_RIGHT);

		immediate_current_keys[key_binds[keys::bind_z]] |= gamepad_pressed(gamepad_state, gamepad_binds[keys::z_symbol_index]);
		immediate_current_keys[key_binds[keys::bind_x]] |= gamepad_pressed(gamepad_state, gamepad_binds[keys::x_symbol_index]);
		immediate_current_keys[key_binds[keys::bind_shift]] |= gamepad_pressed(gamepad_state, gamepad_binds[keys::shift_symbol_index]);
	}

	RxInput* __thiscall RxInputControlChangeHook::update_keys_hook() {
		RxInput* ret = (this->*orig_update_keys)();
		process_gamepad_inputs();
		return ret;
	}

	bool RxInputControlChangeHook::gamepad_pressed(const GLFWgamepadstate& gamepad_state, int key) {
		return gamepad_state.buttons[key] == GLFW_TRUE;
	}

	bool RxInputControlChangeHook::gamepad_axed(const GLFWgamepadstate& gamepad_state, int axis, bool negative) {
		bool inverted = (axis == GLFW_GAMEPAD_AXIS_LEFT_X && gamepad_x_inverted) || (axis == GLFW_GAMEPAD_AXIS_LEFT_Y && gamepad_y_inverted);
		return (negative ^ inverted) ? gamepad_state.axes[axis] < -gamepad_deadzone : gamepad_state.axes[axis] > gamepad_deadzone;
	}

	RubyValue __cdecl RxInputControlChangeHook::mod_loader_gamepad_set_deadzone(RubyValue module, RubyValue deadzone_value) {
		int deadzone = rb_parse_int(deadzone_value);

		gamepad_deadzone = std::min(deadzone, 255) / 255.f;

		return ruby_true;
	}

	RubyValue __cdecl RxInputControlChangeHook::mod_loader_gamepad_bind(RubyValue module, RubyValue button_value, RubyValue button_action_value) {
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

	RubyValue __cdecl RxInputControlChangeHook::mod_loader_gamepad_set_invert_x(RubyValue module, RubyValue invert_x_value) {
		if (invert_x_value != ruby_true && invert_x_value != ruby_false) {
			return ruby_false;
		}
		gamepad_x_inverted = invert_x_value == ruby_true;
		return ruby_true;
	}

	RubyValue __cdecl RxInputControlChangeHook::mod_loader_gamepad_set_invert_y(RubyValue module, RubyValue invert_y_value) {
		if (invert_y_value != ruby_true && invert_y_value != ruby_false) {
			return ruby_false;
		}
		gamepad_y_inverted = invert_y_value == ruby_true;
		return ruby_true;
	}

	void apply_controls_change() {
		mod_loader->hook_api_function(L"user32.dll", "GetKeyState", &ControlsChangeHooks::get_key_state_hook, &ControlsChangeHooks::orig_GetKeyState);

		mod_loader->hook_method(input_update_keys, &RxInputControlChangeHook::update_keys_hook, &RxInputControlChangeHook::orig_update_keys);
		input_update_keys = static_cast<decltype(input_update_keys)>(&RxInputControlChangeHook::update_keys_hook);

		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("hook_key", &ControlsChangeHooks::mod_loader_hook_key);

			mod_loader->register_ruby_method("gamepad_deadzone=", &RxInputControlChangeHook::mod_loader_gamepad_set_deadzone);
			mod_loader->register_ruby_method("gamepad_bind", &RxInputControlChangeHook::mod_loader_gamepad_bind);
			mod_loader->register_ruby_method("gamepad_invert_x=", &RxInputControlChangeHook::mod_loader_gamepad_set_invert_x);
			mod_loader->register_ruby_method("gamepad_invert_y=", &RxInputControlChangeHook::mod_loader_gamepad_set_invert_y);
		});
	}
}