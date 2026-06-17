#include "SteamOverlayHooks.hpp"

#include "../ModLoader.hpp"
#include "../SteamOverlay/SteamOverlay.hpp"

#include "../SteamOverlay/DLLResolver.hpp"

namespace rm_modloader {

	// Cached DIBSection-backed memory DC
	static HDC s_memDC = nullptr;
	static HBITMAP s_memBmp = nullptr;
	static void* s_memBits = nullptr;
	static int s_memW = 0, s_memH = 0;

	struct ScreenHook : Screen {
		static int(__thiscall Screen::* orig_render_all_to_screen)(Surface* a1, int x, int y, RECT* rect);

		int __thiscall render_all_to_screen_hook(Surface* a1, int x, int y, RECT* rect) {
			static const bool render_top_down = true;

			int ret = (this->*orig_render_all_to_screen)(a1, x, y, rect);
			SteamOverlay_RenderFrame(reinterpret_cast<uint32_t*>(this->surface->image.bits),
				this->surface->info.bitmap->bmiHeader.biWidth,
				this->surface->info.bitmap->bmiHeader.biHeight,
				render_top_down);
			return ret;
		}
	};

	int(__thiscall Screen::* ScreenHook::orig_render_all_to_screen)(Surface* a1, int x, int y, RECT* rect) = nullptr;

	void apply_steam_overlay_hooks() {
		auto steam_overlay_config = mod_loader->get_config().get("steam_overlay");
		if (!steam_overlay_config || !steam_overlay_config->get<bool>()) {
			mod_loader->log_info("Steam overlay disabled in config\n");
			return;
		}

		mod_loader->add_preinit_handler([] {
			if (!SteamOverlay_Init(mod_loader->get_game()->window_handle)) {
				mod_loader->log_error("Failed to init steam overlay!\n");
				//mod_loader->log_error("hwnd={}\n", reinterpret_cast<uintptr_t>(mod_loader->get_game()->window_handle));
				return;
			}

			mod_loader->hook_method(0x110BE0, &ScreenHook::render_all_to_screen_hook, &ScreenHook::orig_render_all_to_screen);
		});

		mod_loader->log_info("Applied steam overlay hooks\n");
	}
}