#define NOMINMAX
#include "DisplayHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMGlobal.hpp"
#include "../DisplayGeometry.hpp"
#include "../DisplayFilter.hpp"
#include "MapFrameProbe.hpp"
#include <ddraw.h>
#include <algorithm>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>

namespace rm_modloader {
namespace {
    bool borderless = false;
    bool preserve_aspect = true;
    bool smooth_filter = false;
    uint64_t gdi_filtered = 0, ddraw_filtered = 0, filter_fallbacks = 0;
    bool window_saved = false;
    WINDOWPLACEMENT saved_placement = {sizeof(WINDOWPLACEMENT)};
    LONG_PTR saved_style = 0;
    int requested_width = 0, requested_height = 0;
    bool pending_window = false;
    bool resize_requested = true;
    WNDPROC original_window_proc = nullptr;
    thread_local Screen* presenting = nullptr;

    HWND game_window() { return mod_loader->get_game()->window_handle; }

    // Ruby scripts run before HRFix's postinit resize. Apply persisted choices
    // on the first presentation, after every subsystem has finished setup.
    bool apply_window() {
        HWND hwnd = game_window();
        MONITORINFO monitor = {sizeof(MONITORINFO)};
        if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor))
            return false;
        if (borderless) {
            if (!window_saved) {
                saved_placement.length = sizeof(saved_placement);
                if (!GetWindowPlacement(hwnd, &saved_placement)) return false;
                saved_style = GetWindowLongPtrW(hwnd, GWL_STYLE);
                window_saved = true;
            }
            ShowWindow(hwnd, SW_RESTORE);
            SetWindowLongPtrW(hwnd, GWL_STYLE,
                (saved_style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP | WS_VISIBLE);
            const RECT& r = monitor.rcMonitor;
            return SetWindowPos(hwnd, HWND_NOTOPMOST, r.left, r.top,
                r.right - r.left, r.bottom - r.top, SWP_FRAMECHANGED | SWP_NOACTIVATE) != FALSE;
        }
        if (window_saved) {
            SetWindowLongPtrW(hwnd, GWL_STYLE, saved_style);
            SetWindowPlacement(hwnd, &saved_placement);
            SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            window_saved = false;
        }
        if (!resize_requested) return true;
        Screen* screen = mod_loader->get_game()->screen;
        const int width = requested_width ? requested_width : screen->rect.right - screen->rect.left;
        const int height = requested_height ? requested_height : screen->rect.bottom - screen->rect.top;
        ShowWindow(hwnd, SW_RESTORE);
        RECT r = {0, 0, width, height};
        AdjustWindowRectEx(&r, DWORD(GetWindowLongPtrW(hwnd, GWL_STYLE)),
            GetMenu(hwnd) != nullptr, DWORD(GetWindowLongPtrW(hwnd, GWL_EXSTYLE)));
        const RECT& work = monitor.rcWork;
        const int w = std::min<int>(r.right - r.left, work.right - work.left);
        const int h = std::min<int>(r.bottom - r.top, work.bottom - work.top);
        bool success = SetWindowPos(hwnd, nullptr, work.left + (work.right - work.left - w) / 2,
            work.top + (work.bottom - work.top - h) / 2, w, h,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED) != FALSE;
        if (success) resize_requested = false;
        return success;
    }

    RECT fitted_rect(const RECT& bounds, const Screen* screen) {
        auto fit = display::fit(bounds.right - bounds.left, bounds.bottom - bounds.top,
            screen->rect.right - screen->rect.left, screen->rect.bottom - screen->rect.top, preserve_aspect);
        return {bounds.left + fit.x, bounds.top + fit.y,
            bounds.left + fit.x + fit.width, bounds.top + fit.y + fit.height};
    }

    template<class Fill>
    void fill_bars(const RECT& bounds, const RECT& image, Fill fill) {
        RECT bars[] = {
            {bounds.left, bounds.top, bounds.right, image.top},
            {bounds.left, image.bottom, bounds.right, bounds.bottom},
            {bounds.left, image.top, image.left, image.bottom},
            {image.right, image.top, bounds.right, image.bottom}
        };
        for (auto& r : bars)
            if (r.right > r.left && r.bottom > r.top) fill(r);
    }

    LRESULT CALLBACK display_window_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
        struct TraceScope {
            bool enabled;
            UINT message;
            std::chrono::steady_clock::time_point begin;
            explicit TraceScope(UINT value) : enabled(map_frame_trace_recording()), message(value) {
                if (enabled) begin=std::chrono::steady_clock::now();
            }
            ~TraceScope() {
                if (enabled) map_frame_trace_wndproc(
                    std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count(),
                    message);
            }
        } trace(message);
        if (message == WM_ERASEBKGND) {
            RECT bounds = {};
            GetClientRect(window, &bounds);
            RECT image = fitted_rect(bounds, mod_loader->get_game()->screen);
            fill_bars(bounds, image, [&](RECT& bar) {
                FillRect(reinterpret_cast<HDC>(wp), &bar, (HBRUSH)GetStockObject(BLACK_BRUSH));
            });
            // The engine paints the image. Clearing only the bars avoids
            // flashing a black frame during an ordinary repaint.
            return 1;
        }
        Screen* previous = presenting;
        // WM_PAINT can blit directly without entering update_screen. Give it
        // the same scaling as the regular frame, or it can overwrite a bar
        // with an unscaled fragment of the game at the upper-left corner.
        if (message == WM_PAINT) presenting = mod_loader->get_game()->screen;
        LRESULT result = CallWindowProcW(original_window_proc, window, message, wp, lp);
        presenting = previous;
        if (message == WM_SIZE && wp != SIZE_MINIMIZED) {
            // Windows otherwise preserves the old upper-left client pixels.
            // Invalidate even while the engine is paused during live resizing.
            InvalidateRect(window, nullptr, TRUE);
        }
        return result;
    }

    // Only the engine's final window presentation is transformed. Texture
    // copies, overlay rendering, screenshots and other processes keep their
    // original coordinates. The original update retains surface recovery and
    // its existing WaitForVerticalBlank pacing.
    using Blt = HRESULT (WINAPI*)(IDirectDrawSurface*, RECT*, IDirectDrawSurface*, RECT*, DWORD, DDBLTFX*);
    std::unordered_map<void*, Blt> original_blits;
    std::shared_mutex blits_mutex;

    void* blit_address(IDirectDrawSurface* surface) {
        return (*reinterpret_cast<void***>(surface))[5];
    }

    HRESULT WINAPI blit_hook(IDirectDrawSurface* target, RECT* destination,
                            IDirectDrawSurface* source, RECT* source_rect, DWORD flags, DDBLTFX* fx) {
        Blt original;
        {
            std::shared_lock lock(blits_mutex);
            original = original_blits.at(blit_address(target));
        }
        if (!presenting || !destination ||
            reinterpret_cast<uintptr_t>(target) != presenting->gapD0[0] ||
            reinterpret_cast<uintptr_t>(source) != presenting->gapD0[1])
            return original(target, destination, source, source_rect, flags, fx);
        RECT image = fitted_rect(*destination, presenting);
        DDBLTFX black = {};
        black.dwSize = sizeof(black);
        fill_bars(*destination, image, [&](RECT& bar) {
            original(target, &bar, nullptr, nullptr, DDBLT_COLORFILL | DDBLT_WAIT, &black);
        });
        // Native Blt does not provide a portable interpolation selection.
        // Use the same explicit GDI filter as the window path when scaling.
        DDSURFACEDESC desc = {}; desc.dwSize = sizeof(desc);
        if ((flags & ~DWORD(DDBLT_WAIT)) == 0 &&
            (source_rect || SUCCEEDED(source->GetSurfaceDesc(&desc)))) {
            const int sw = source_rect ? source_rect->right-source_rect->left : int(desc.dwWidth);
            const int sh = source_rect ? source_rect->bottom-source_rect->top : int(desc.dwHeight);
            if (sw != image.right-image.left || sh != image.bottom-image.top) {
                const HRESULT result = stretch_display_surface(target, image, source, source_rect, smooth_filter);
                if (SUCCEEDED(result)) { ++ddraw_filtered; return result; }
                if (++filter_fallbacks == 1)
                    mod_loader->log_warning("Display: explicit scaling filter unavailable on DirectDraw surface; using native Blt\n");
            }
        }
        return original(target, &image, source, source_rect, flags, fx);
    }

    decltype(&BitBlt) original_bitblt = nullptr;
    BOOL WINAPI bitblt_hook(HDC target, int x, int y, int w, int h,
                           HDC source, int sx, int sy, DWORD operation) {
        if (!presenting || WindowFromDC(target) != presenting->window_handle)
            return original_bitblt(target, x, y, w, h, source, sx, sy, operation);
        RECT bounds;
        if (!GetClientRect(presenting->window_handle, &bounds)) return FALSE;
        RECT image = fitted_rect(bounds, presenting);
        const int sw = presenting->rect.right - presenting->rect.left;
        const int sh = presenting->rect.bottom - presenting->rect.top;
        if (sw <= 0 || sh <= 0) return FALSE;
        // RGSS may render in tiles: transform both edges so adjacent tiles
        // share exactly the same boundary even at fractional scaling factors.
        int left = image.left + int(int64_t(x) * (image.right - image.left) / sw);
        int top = image.top + int(int64_t(y) * (image.bottom - image.top) / sh);
        int right = image.left + int(int64_t(x + w) * (image.right - image.left) / sw);
        int bottom = image.top + int(int64_t(y + h) * (image.bottom - image.top) / sh);
        fill_bars(bounds, image, [&](RECT& bar) { FillRect(target, &bar, (HBRUSH)GetStockObject(BLACK_BRUSH)); });
        const RECT output = {left, top, right, bottom};
        const RECT input = {sx, sy, sx+w, sy+h};
        const bool result = stretch_display(target, output, source, input, operation, smooth_filter);
        if (result) ++gdi_filtered;
        return result ? TRUE : FALSE;
    }

    struct DisplayScreen : Screen {
        static int (__thiscall Screen::*original_update)(int, int);
        static int (__thiscall Screen::*original_resize)(int, int, bool);
        int __thiscall update(int a, int b) {
            if (pending_window) {
                pending_window = false;
                if (!apply_window()) mod_loader->log_warning("Display: could not apply window settings\n");
            }
            if (gapD0[0] && gapD0[1]) {
                void* address = blit_address(reinterpret_cast<IDirectDrawSurface*>(gapD0[0]));
                Blt* original = nullptr;
                {
                    std::unique_lock lock(blits_mutex);
                    auto [it, inserted] = original_blits.emplace(address, nullptr);
                    if (inserted) original = &it->second;
                }
                // MinHook suspends other threads. Do not hold our map lock
                // while installing: a suspended reader could own that lock.
                if (original) mod_loader->hook_function(address, &blit_hook, original);
            }
            Screen* previous = presenting;
            presenting = this;
            int result = (this->*original_update)(a, b);
            presenting = previous;
            return result;
        }
        int __thiscall resize(int w, int h, bool /*exclusive*/) {
            // Keep engine display changes windowed, including its Alt+Enter
            // path. Borderless mode is controlled independently of game size.
            int result = (this->*original_resize)(w, h, false);
            resize_requested = true;
            pending_window = true;
            return result;
        }
    };
    int (__thiscall Screen::*DisplayScreen::original_update)(int, int) = nullptr;
    int (__thiscall Screen::*DisplayScreen::original_resize)(int, int, bool) = nullptr;

    RubyValue __cdecl configure(RubyValue, RubyValue mode, RubyValue width, RubyValue height, RubyValue scaling) {
        int m = rb_parse_int(mode), w = rb_parse_int(width), h = rb_parse_int(height);
        int s = rb_parse_int(scaling);
        if (m < 0 || m > 1 || s < 0 || s > 1 || w < 0 || h < 0 || w > 16384 || h > 16384 || ((w == 0) != (h == 0)))
            return ruby_false;
        // Scaling only changes presentation geometry; do not move/restore the
        // window when the user changes it (in particular a maximized window).
        pending_window = pending_window || resize_requested || borderless != (m == 1) ||
            w != requested_width || h != requested_height;
        borderless = m == 1;
        if (preserve_aspect != (s == 0)) {
            preserve_aspect = s == 0;
            InvalidateRect(game_window(), nullptr, TRUE);
        }
        resize_requested = resize_requested || w != requested_width || h != requested_height;
        requested_width = w;
        requested_height = h;
        return ruby_true;
    }

    RubyValue __cdecl set_filter(RubyValue, RubyValue value) {
        const int filter = rb_parse_int(value);
        if (filter < 0 || filter > 1) return ruby_false;
        if (smooth_filter != (filter == 1)) {
            smooth_filter = filter == 1;
            InvalidateRect(game_window(), nullptr, TRUE);
        }
        return ruby_true;
    }

    RubyValue __cdecl filter_status(RubyValue) {
        const auto report = nlohmann::json{{"filter", smooth_filter ? 1 : 0},
            {"gdi_calls", gdi_filtered}, {"ddraw_calls", ddraw_filtered},
            {"fallbacks", filter_fallbacks}}.dump();
        return rb_str_new(report.data(), static_cast<long>(report.size()));
    }
}

RECT display_output_bounds(HWND window) {
    RECT bounds = {};
    GetClientRect(window, &bounds);
    RECT image = fitted_rect(bounds, mod_loader->get_game()->screen);
    POINT origin = {0, 0};
    ClientToScreen(window, &origin);
    OffsetRect(&image, origin.x, origin.y);
    return image;
}

void apply_display_hooks() {
    mod_loader->hook_method(0x10E660, &DisplayScreen::update, &DisplayScreen::original_update);
    mod_loader->hook_method(screen_resize_screen, &DisplayScreen::resize, &DisplayScreen::original_resize);
    mod_loader->hook_api_function(L"gdi32.dll", "BitBlt", &bitblt_hook, &original_bitblt);
    mod_loader->add_preinit_handler([] {
        mod_loader->register_ruby_method("configure_display", &configure);
        mod_loader->register_ruby_method("set_display_scaling_filter", &set_filter);
        mod_loader->register_ruby_method("display_scaling_filter_status", &filter_status);
        original_window_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
            game_window(), GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&display_window_proc)));
    });
}
}
