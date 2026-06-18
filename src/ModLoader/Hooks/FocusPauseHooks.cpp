#include "FocusPauseHooks.hpp"
#include "../ModLoader.hpp"

#include <Windows.h>
#include <mmsystem.h> // joyGetPosEx / JOYINFOEX / JOYERR_NOCANDO

#include <atomic>
#include <cstring>

namespace rm_modloader {

	namespace {

		// Keeping the game ticking when its window loses focus, WITHOUT letting it
		// act on background input. Three layers:
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
		//
		// 3. Gate input on the REAL focus. With pause disabled the still-running
		//    engine keeps polling input; but RGSS reads keys via GetKeyState
		//    (RxInput_update_keys does GetKeyState(vk) < 0), the legacy joystick
		//    via joyGetPosEx, and ModLoader's own ExtendedControlSet via
		//    GetKeyboardState. Those are focus-independent (global/async, or
		//    message-synced state that sticks "down" on focus loss because no
		//    WM_KEYUP is delivered), so the game would act on keys pressed in
		//    other apps / stuck keys ("plays itself" — can wipe a save). We force
		//    them to report "nothing pressed" whenever the app isn't foreground.

		decltype(&WaitMessage)         orig_WaitMessage         = nullptr;
		decltype(&GetActiveWindow)     orig_GetActiveWindow     = nullptr;
		decltype(&GetForegroundWindow) orig_GetForegroundWindow = nullptr;

		WNDPROC orig_wnd_proc = nullptr;
		HWND    g_game_hwnd   = nullptr;

		// Real app-foreground state, maintained from WM_ACTIVATEAPP (see the
		// WindowProc). Starts true so input works before the first activation msg.
		std::atomic<bool> g_window_focused{ true };

		decltype(&GetKeyState)      orig_GetKeyState      = nullptr;
		decltype(&GetAsyncKeyState) orig_GetAsyncKeyState = nullptr;
		decltype(&GetKeyboardState) orig_GetKeyboardState = nullptr;
		decltype(&joyGetPosEx)      orig_joyGetPosEx      = nullptr;

		// While unfocused, report all keys up / no joystick without reading
		// further; otherwise read the real state through the chain trampoline.
		SHORT WINAPI get_key_state_hook(int nVirtKey) {
			return g_window_focused.load(std::memory_order_relaxed) ? orig_GetKeyState(nVirtKey) : 0;
		}

		SHORT WINAPI get_async_key_state_hook(int vKey) {
			return g_window_focused.load(std::memory_order_relaxed) ? orig_GetAsyncKeyState(vKey) : 0;
		}

		BOOL WINAPI get_keyboard_state_hook(PBYTE lpKeyState) {
			if (!g_window_focused.load(std::memory_order_relaxed)) {
				std::memset(lpKeyState, 0, 256);
				return TRUE;
			}
			return orig_GetKeyboardState(lpKeyState);
		}

		MMRESULT WINAPI joy_get_pos_ex_hook(UINT uJoyID, LPJOYINFOEX pji) {
			if (!g_window_focused.load(std::memory_order_relaxed)) {
				return JOYERR_NOCANDO;
			}
			return orig_joyGetPosEx(uJoyID, pji);
		}

		LRESULT CALLBACK subclassed_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
			switch (msg) {
			case WM_ACTIVATEAPP:
				// Record the REAL app-foreground state for input gating, THEN
				// force "activating" so the engine's own flag stays true.
				g_window_focused.store(wp != FALSE, std::memory_order_relaxed);
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

	bool is_window_focused() {
		// When the focus-pause subclass is installed, g_window_focused is the
		// authoritative real-focus state (GetForegroundWindow is hooked to lie, so it
		// cannot be queried directly). Otherwise the feature is off, nothing is hooked,
		// and we can ask the OS straight whether our window is the foreground one.
		if (g_game_hwnd) {
			return g_window_focused.load(std::memory_order_relaxed);
		}
		HWND foreground = GetForegroundWindow();
		if (!foreground) {
			return false;
		}
		DWORD pid = 0;
		GetWindowThreadProcessId(foreground, &pid);
		return pid == GetCurrentProcessId();
	}

	void apply_focus_pause_hooks() {
		auto config_value = mod_loader->get_config().get("disable_focus_pause");
		if (!config_value || !config_value->get<bool>()) {
			mod_loader->log_info("focus_pause: disable_focus_pause off in config — game pauses on focus loss\n");
			return;
		}

		// API-level safety net first.
		mod_loader->hook_api_function(L"user32.dll", "WaitMessage",         wait_message_hook,          &orig_WaitMessage);
		mod_loader->hook_api_function(L"user32.dll", "GetActiveWindow",     get_active_window_hook,     &orig_GetActiveWindow);
		mod_loader->hook_api_function(L"user32.dll", "GetForegroundWindow", get_foreground_window_hook, &orig_GetForegroundWindow);

		// Input gating by real focus. These compose with other input hooks via
		// the loader's hook chain (e.g. ControlsChangeHooks also hooks
		// GetKeyState). Order is irrelevant for safety: while unfocused this hook
		// returns "up" without reading deeper, so the whole chain yields no input.
		mod_loader->hook_api_function(L"user32.dll", "GetKeyState",      get_key_state_hook,       &orig_GetKeyState);
		mod_loader->hook_api_function(L"user32.dll", "GetAsyncKeyState", get_async_key_state_hook, &orig_GetAsyncKeyState);
		mod_loader->hook_api_function(L"user32.dll", "GetKeyboardState", get_keyboard_state_hook,  &orig_GetKeyboardState);
		mod_loader->hook_api_function(L"winmm.dll",  "joyGetPosEx",      joy_get_pos_ex_hook,      &orig_joyGetPosEx);

		// Main weapon: subclass the WindowProc once the game window exists. We
		// queue this into the post-init phase because at hook-application time
		// the window has not been created yet.
		mod_loader->add_postinit_handler([] {
			install_subclass();
		});

		mod_loader->log_info("focus_pause: disabled — game will keep ticking while window loses focus\n");
	}
}
