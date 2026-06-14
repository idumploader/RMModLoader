#include "FocusPauseHooks.hpp"
#include "../ModLoader.hpp"

#include <Windows.h>

namespace rm_modloader {

	namespace {

		// Two layers of defense for keeping the game ticking when its window
		// loses focus:
		//
		// 1. Subclass the game's main window. RGSS3's own WindowProc sets an
		//    internal "is_active" flag from WM_ACTIVATEAPP / WM_KILLFOCUS /
		//    WM_ACTIVATE; the engine's main loop checks that flag and stops
		//    updating when false. We swallow these messages so the flag never
		//    flips off in the first place.
		//
		// 2. Hook WaitMessage to return immediately with a short Sleep, plus
		//    lie about GetActiveWindow / GetForegroundWindow. These cover any
		//    fallback code paths that don't go through the WindowProc.

		decltype(&WaitMessage)         orig_WaitMessage         = nullptr;
		decltype(&GetActiveWindow)     orig_GetActiveWindow     = nullptr;
		decltype(&GetForegroundWindow) orig_GetForegroundWindow = nullptr;

		WNDPROC orig_wnd_proc = nullptr;
		HWND    g_game_hwnd   = nullptr;

		LRESULT CALLBACK subclassed_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
			switch (msg) {
			case WM_ACTIVATEAPP:
				// Force "activating" so the engine's flag stays true.
				wp = TRUE;
				break;
			case WM_ACTIVATE:
				wp = WA_ACTIVE;
				break;
			case WM_KILLFOCUS:
				// Swallow — pretend focus was never lost.
				return 0;
			default:
				break;
			}
			return CallWindowProcW(orig_wnd_proc, hwnd, msg, wp, lp);
		}

		BOOL CALLBACK find_main_window(HWND hwnd, LPARAM lparam) {
			DWORD pid = 0;
			GetWindowThreadProcessId(hwnd, &pid);
			if (pid != GetCurrentProcessId()) return TRUE;
			if (GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE; // skip owned popups
			if (!IsWindowVisible(hwnd)) return TRUE;
			*reinterpret_cast<HWND*>(lparam) = hwnd;
			return FALSE; // stop
		}

		void install_subclass() {
			if (g_game_hwnd) return;
			HWND hwnd = nullptr;
			EnumWindows(find_main_window, reinterpret_cast<LPARAM>(&hwnd));
			if (!hwnd) {
				mod_loader->log_warning("focus_pause: could not find game window for subclassing\n");
				return;
			}
			g_game_hwnd = hwnd;
			orig_wnd_proc = reinterpret_cast<WNDPROC>(
				SetWindowLongPtrW(hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(subclassed_wnd_proc))
			);
			mod_loader->log_info("focus_pause: subclassed game WindowProc (hwnd={:#x})\n",
				reinterpret_cast<uintptr_t>(hwnd));
		}

		BOOL WINAPI wait_message_hook() {
			// Don't actually block — sleep a single frame so the loop continues.
			Sleep(16);
			return TRUE;
		}

		HWND WINAPI get_active_window_hook() {
			HWND actual = orig_GetActiveWindow();
			return g_game_hwnd ? g_game_hwnd : actual;
		}

		HWND WINAPI get_foreground_window_hook() {
			HWND actual = orig_GetForegroundWindow();
			return g_game_hwnd ? g_game_hwnd : actual;
		}

	} // anonymous namespace

	void apply_focus_pause_hooks() {
		auto config_value = mod_loader->get_config().get("disable_focus_pause");
		if (!config_value || !config_value->get<bool>()) {
			return;
		}

		// API-level safety net first.
		mod_loader->hook_api_function(L"user32.dll", "WaitMessage",         wait_message_hook,          &orig_WaitMessage);
		mod_loader->hook_api_function(L"user32.dll", "GetActiveWindow",     get_active_window_hook,     &orig_GetActiveWindow);
		mod_loader->hook_api_function(L"user32.dll", "GetForegroundWindow", get_foreground_window_hook, &orig_GetForegroundWindow);

		// Main weapon: subclass the WindowProc once the game window exists. We
		// queue this into the post-init phase because at hook-application time
		// the window has not been created yet.
		mod_loader->add_postinit_handler([] {
			install_subclass();
		});

		mod_loader->log_info("focus_pause: disabled — game will keep ticking while window loses focus\n");
	}
}
