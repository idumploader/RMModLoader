#include "ControlsChangeHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"

#include <array>

#undef max
#undef min

namespace rm_modloader {
	decltype(&GetKeyState) ControlsChangeHooks::orig_GetKeyState = nullptr;

	std::array<int, 0xFF> controls_changer_binds = { 0 };

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
		controls_changer_binds[orig_virt_key] = virt_key;
		return ruby_true;
	}

	void apply_controls_change() {
		if (const auto* c = mod_loader->get_config().get("controls_change"); c && !c->get<bool>()) {
			mod_loader->log_info("ControlsChange disabled in config\n");
			return;
		}

		mod_loader->hook_api_function(L"user32.dll", "GetKeyState", &ControlsChangeHooks::get_key_state_hook, &ControlsChangeHooks::orig_GetKeyState);

		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("hook_key", &ControlsChangeHooks::mod_loader_hook_key);
		});
	}
}