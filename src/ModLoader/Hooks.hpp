#pragma once
#include "Hooks/HRFixHooks.hpp"
#include "Hooks/FastRenderHooks.hpp"
#include "Hooks/ControlsChangeHooks.hpp"
#include "Hooks/IntegratedHooks.hpp"
#include "Hooks/SteamSupportHooks.hpp"
#include "Hooks/FileManagerHooks.hpp"
#include "Hooks/SteamOverlayHooks.hpp"
#include "Hooks/SpriteDisposeFixHooks.hpp"
#include "Hooks/HttpServerHooks.hpp"

#include <array>

namespace rm_modloader {
	using HookApplierFunc = void(*)();

	std::array hooks_appliers = {
		apply_integrated_hooks,
		apply_hrfix,
		apply_fast_render,
		apply_steam_support_hooks,
		apply_controls_change,
		apply_file_manager_hooks,
		apply_steam_overlay_hooks,
		apply_sprite_dispose_fix,
		apply_http_server_hooks
	};
}