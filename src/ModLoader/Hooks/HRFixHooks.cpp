#define NOMINMAX
#include "HRFixHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"
#include "../RMGlobal.hpp"
#include "../GLFWMisc.hpp"

#include <future>
#include <thread>
#include <mutex>
#include <condition_variable>

namespace rm_modloader {

    int hrfix_render_width = 640;
    int hrfix_render_height = 480;

    std::pair<int, int> offset_screen_size(int width, int height) {
        RECT system_client_rect;
        SystemParametersInfoA(SPI_GETWORKAREA, 0, &system_client_rect, 0);
        int working_height = system_client_rect.bottom - system_client_rect.top;
        int working_width = system_client_rect.right - system_client_rect.left;

        TITLEBARINFOEX title_bar_info = { sizeof(TITLEBARINFOEX) };
        SendMessage(mod_loader->get_game()->window_handle, WM_GETTITLEBARINFOEX, 0, reinterpret_cast<LPARAM>(&title_bar_info));
        int title_bar_height = (title_bar_info.rcTitleBar.bottom - title_bar_info.rcTitleBar.top);

        return std::make_pair(
            std::min(working_width, width),
            std::min(working_height - title_bar_height, height)
        );
    }

    bool is_cut_disabled_map(RxTilemap* tilemap) {
        RxPatchTilemap* patched_tilemap = reinterpret_cast<RxPatchTilemap*>(tilemap);
        return patched_tilemap->map_id == 90;
    }

    inline RxPatchTilemap* get_patch_tilemap_from_rb(void* ruby_data) {
        return at_address<RxPatchTilemap*>(at_address<void*>(ruby_data, 16), 8);
    }

    template<typename T>
    T* rgss_get_rb_data(RubyValue ruby_data) {
        return at_address<T*>(get_rb_data_data<void>(ruby_data), 8);
    }

    int TilemapMapIDPatch::tilemap_initialize_hook(int a1, int a2, void* a3) {
        int ret = orig_tilemap_initialize(a1, a2, a3);

        RxPatchTilemap* tilemap = get_patch_tilemap_from_rb(a3);
        tilemap->map_id = -1;
        mod_loader->log_info("tilemap_initialize: setted map_id to -1 at (0x{:X})\n", reinterpret_cast<uintptr_t>(tilemap));

        return ret;
    }

    void TilemapMapIDPatch::init_rb_tilemap_hook() {
        orig_init_rb_tilemap();

        RubyValue global_rb_tilemap = *at_offset<RubyValue*>(rgss_module, 0x26A0B4);

        rb_define_method(global_rb_tilemap, "map_id=", patch_tilemap_set_map_id, 1);
    }

    int TilemapMapIDPatch::patch_tilemap_set_map_id(void* ruby_data, int map_id_object) {
        RxPatchTilemap* tilemap = get_patch_tilemap_from_rb(ruby_data);
        tilemap->map_id = rb_parse_int(map_id_object);

        return map_id_object;
    }

    int(__cdecl* TilemapMapIDPatch::orig_tilemap_initialize)(int a1, int a2, void* a3) = nullptr;
    void(__cdecl* TilemapMapIDPatch::orig_init_rb_tilemap)() = nullptr;

    int RxTilemapSpriteHRFixHook::render_tilemap_tiles_hook(Surface* surf, RECT* in_rect) {
        static int old_tile_width = -1, old_tile_height = -1;

        auto tilesize_width = mod_loader->at_base_offset_as<char*>(0x21E01);
        auto tilesize_height = mod_loader->at_base_offset_as<char*>(0x21D7D);

        // TODO: round this char type
        if (!is_cut_disabled_map(tilemap)) {
            *tilesize_width = static_cast<char>(std::min(static_cast<LONG>(tilemap->width), (rect.right - rect.left) / 32 + 1)); // +1 tile for seamless screen scroll
            *tilesize_height = static_cast<char>(std::min(static_cast<LONG>(tilemap->height), (rect.bottom - rect.top) / 32 + 1)); // +1 tile for seamless screen scroll
        }
        else {
            *tilesize_width = static_cast<char>((rect.right - rect.left) / 32 + 1); // +1 tile for seamless screen scroll
            *tilesize_height = static_cast<char>((rect.bottom - rect.top) / 32 + 1); // +1 tile for seamless screen scroll
        }

        if (*tilesize_width != old_tile_width || *tilesize_height != old_tile_height) {
            old_tile_width = *tilesize_width;
            old_tile_height = *tilesize_height;

            mod_loader->log_info("render_tilemap_tiles: tilemap (0x{:X}), map_id={}\n", reinterpret_cast<uintptr_t>(tilemap), reinterpret_cast<RxPatchTilemap*>(tilemap)->map_id);
            mod_loader->log_info("render_tilemap_tiles: changed render tile size to {}x{}\n", old_tile_width, old_tile_height);
        }

        return (this->*orig_render_tilemap_tiles)(surf, in_rect);
    }

    int(__thiscall RxTilemapSprite::* RxTilemapSpriteHRFixHook::orig_render_tilemap_tiles)(Surface* surf, RECT* rect) = nullptr;

    int SurfaceHRFixHook::init_surface_bitmap_hook(int width, int height) {
        if (width == hrfix_render_width && height == 41) { // TODO: change
            height = hrfix_render_height;
        }

        return (this->*orig_init_surface_bitmap)(width, height);
    }

    int(__thiscall Surface::* SurfaceHRFixHook::orig_init_surface_bitmap)(int width, int height) = nullptr;

    int SpriteHRFixHook::set_sprite_offset_hook(int x, int y) {
        auto loc = get_object_locator(this);

        static Sprite* tilemap_ancestor = nullptr;
        static int map_offset_x = 0, map_offset_y = 0;
        static bool is_last_disabled = 0;
        if (loc->type_info->name() == RxTilemapSprite::type_name) {
            auto tilemap_sprite = reinterpret_cast<RxTilemapSprite*>(this);
            if (tilemap_ancestor != ancestor
                || tilemap_sprite->tilemap->width != current_map_width
                || tilemap_sprite->tilemap->height != current_map_height
                || is_last_disabled != is_cut_disabled_map(tilemap_sprite->tilemap)
                ) {
                current_map_width = tilemap_sprite->tilemap->width;
                current_map_height = tilemap_sprite->tilemap->height;
                tilemap_ancestor = ancestor;

                Screen* screen = (*rgss_game)->screen;
                int screen_width = screen->rect.right - screen->rect.left;
                int screen_height = screen->rect.bottom - screen->rect.top;

                is_last_disabled = is_cut_disabled_map(tilemap_sprite->tilemap);
                if (!is_cut_disabled_map(tilemap_sprite->tilemap)) {
                    map_offset_x = std::max(screen_width - (current_map_width * 32), 0) / 2;
                    map_offset_y = std::max(screen_height - (current_map_height * 32), 0) / 2;
                }
                else {
                    map_offset_x = 0;
                    map_offset_y = 0;
                }

                mod_loader->log_info("set_sprite_offset: tilemap map_id={}\n", reinterpret_cast<RxPatchTilemap*>(tilemap_sprite->tilemap)->map_id);
                mod_loader->log_info("set_sprite_offset: new offset x={}, y={}\n", map_offset_x, map_offset_y);
                mod_loader->log_info("set_sprite_offset: map changed width={}, height={}\n", current_map_width, current_map_height);
            }
        }

        bool is_not_background_parallax = tilemap_ancestor == ancestor && loc->type_info->name() != RxPlane::type_name;
        x += is_not_background_parallax ? map_offset_x : 0;
        y += is_not_background_parallax ? map_offset_y : 0;

        return (this->*orig_set_sprite_offset)(x, y);
    }

    int SpriteHRFixHook::set_rect_hook(RECT* new_rect) {
        return (this->*orig_set_rect)(new_rect);
    }

    int(__thiscall Sprite::* SpriteHRFixHook::orig_set_sprite_offset)(int x, int y) = nullptr;
    int(__thiscall Sprite::* SpriteHRFixHook::orig_set_rect)(RECT* new_rect) = nullptr;
    int SpriteHRFixHook::current_map_width = 0;
    int SpriteHRFixHook::current_map_height = 0;

    void RxInputHRFixHook::toggle_fullscreen() {
        GameFrame* game = mod_loader->get_game();
        if (is_fullscreen) {
            is_fullscreen = false;
            //LONG style = GetWindowLongPtr(game->window_handle, GWL_STYLE);
            SetWindowLongPtr(game->window_handle, GWL_STYLE, WS_VISIBLE | WS_OVERLAPPEDWINDOW);
            SetWindowPos(
                game->window_handle,
                nullptr,
                last_window_rect.left,
                last_window_rect.top,
                last_window_rect.right - last_window_rect.left,
                last_window_rect.bottom - last_window_rect.top,
                SWP_FRAMECHANGED
            );

            auto [adjusted_width, adjusted_height] = offset_screen_size(hrfix_render_width, hrfix_render_height);
            (game->*game_frame_resize_screen)(adjusted_width, adjusted_height);
        }
        else {
            is_fullscreen = true;
            GetWindowRect(game->window_handle, &last_window_rect);

            (game->*game_frame_resize_screen)(hrfix_render_width, hrfix_render_height);

            int screen_width = GetSystemMetrics(SM_CXSCREEN);
            int screen_height = GetSystemMetrics(SM_CYSCREEN);
            //LONG style = GetWindowLongPtr(game->window_handle, GWL_STYLE);

            SetWindowLongPtr(game->window_handle, GWL_STYLE, WS_VISIBLE | WS_POPUP);
            //SetWindowLongPtr(game->window_handle, GWL_EXSTYLE, WS_EX_APPWINDOW |WS_EX_CONTROLPARENT);
            SetWindowPos(game->window_handle, HWND_TOP, 0, 0, screen_width, screen_height, SWP_FRAMECHANGED);
        }
    }

    RxInput* __thiscall RxInputHRFixHook::update_keys_hook() {
        // immediate update fullscreen key
        static SHORT last_fullscreen_key_state = 0;
        SHORT fullscreen_key_state = GetKeyState(windowed_fullscreen_key);
        if (last_fullscreen_key_state >= 0 && fullscreen_key_state < 0) { // key just down
            toggle_fullscreen();
        }
        last_fullscreen_key_state = fullscreen_key_state;

        return (this->*orig_update_keys)();
    }

    RxInput* (__thiscall RxInput::* RxInputHRFixHook::orig_update_keys)() = nullptr;
    bool RxInputHRFixHook::is_fullscreen = false;
    RECT RxInputHRFixHook::last_window_rect = { 0 };

    decltype(&CreateWindowExW) orig_CreateWindowExW = nullptr;

    static HWND WINAPI create_window_ex_hook(
        _In_ DWORD dwExStyle,
        _In_opt_ LPCWSTR lpClassName,
        _In_opt_ LPCWSTR lpWindowName,
        _In_ DWORD dwStyle,
        _In_ int X,
        _In_ int Y,
        _In_ int nWidth,
        _In_ int nHeight,
        _In_opt_ HWND hWndParent,
        _In_opt_ HMENU hMenu,
        _In_opt_ HINSTANCE hInstance,
        _In_opt_ LPVOID lpParam
    ) {
        return orig_CreateWindowExW(
            dwExStyle,
            lpClassName,
            lpWindowName,
            dwStyle | WS_THICKFRAME | WS_MAXIMIZEBOX,
            X,
            Y,
            nWidth,
            nHeight,
            hWndParent,
            hMenu,
            hInstance,
            lpParam
        );
    }

    struct ScreenHRFixHook : Screen {
        static int(__thiscall Screen::* orig_update_screen)(int a1, int a2);

        int __thiscall update_screen_hook(int a1, int a2);
    };

    int __thiscall ScreenHRFixHook::update_screen_hook(int a1, int a2) {
        static std::unique_ptr<char[]> screen_data = std::make_unique<char[]>(2048 * 2048 * 4);
        static std::mutex render_mutex;
        static std::condition_variable render_cv;
        static int render_a1 = a1, render_a2 = a2;
        static std::thread render_thread([this] {
            while (true) {
                std::unique_lock l(render_mutex);
                (this->*orig_update_screen)(render_a1, render_a2);
                render_cv.wait(l);
            }
        });

        std::unique_lock l(render_mutex);

        return 1;
    }
    int(__thiscall Screen::* ScreenHRFixHook::orig_update_screen)(int a1, int a2) = nullptr;

    int(__thiscall Screen::* DisableFullscreenHook::orig_resize_screen)(int width, int height, bool is_fullscreen) = nullptr;

    int __thiscall DisableFullscreenHook::resize_screen_hook(int width, int height, bool is_fullscreen) {
        return (this->*orig_resize_screen)(width, height, false);
    }

    struct TilemapSpriteOffsetHook : RxTilemapSprite {
        static decltype(SpriteVFTable::set_sprite_offset) orig_set_sprite_offset;

        bool __thiscall set_sprite_offset_hook(int x, int y) {
            x += hrfix_render_width / 32 > tilemap->width ? (hrfix_render_width / 32 - tilemap->width) / 2: 0;
            y += hrfix_render_height / 32 > tilemap->height ? (hrfix_render_height / 32 - tilemap->height) / 2 : 0;
            return (this->*orig_set_sprite_offset)(x, y);
            //return true;
        }
    };

    decltype(SpriteVFTable::set_sprite_offset) TilemapSpriteOffsetHook::orig_set_sprite_offset = nullptr;

    static RubyValue __cdecl rx_tilemap_get_x_ruby(RubyValue object) {
        RxTilemap* tilemap = rgss_get_rb_data<RxTilemap>(object);

        return rb_make_number(tilemap->tilemap_sprite8->offset_x);
    }

    static RubyValue __cdecl rx_tilemap_set_x_ruby(RubyValue object, RubyValue x_value) {
        RxTilemap* tilemap = rgss_get_rb_data<RxTilemap>(object);
        int new_x = rb_parse_int(x_value);
        if (tilemap->tilemap_sprite8->offset_x != new_x) {
            RxTilemapSprite* sprite = tilemap->tilemap_sprite8;
            sprite->offset_x = new_x;
            (sprite->*(TilemapSpriteOffsetHook::orig_set_sprite_offset))(sprite->offset_x, sprite->offset_y);
        }
        if (tilemap->tilemap_spriteC->offset_x != new_x) {
            RxTilemapSprite* sprite = tilemap->tilemap_spriteC;
            sprite->offset_x = new_x;
            (sprite->*(TilemapSpriteOffsetHook::orig_set_sprite_offset))(sprite->offset_x, sprite->offset_y);
        }

        return x_value;
    }

    static RubyValue __cdecl rx_tilemap_get_y_ruby(RubyValue object) {
        RxTilemap* tilemap = rgss_get_rb_data<RxTilemap>(object);

        return rb_make_number(tilemap->tilemap_sprite8->offset_y);
    }

    static RubyValue __cdecl rx_tilemap_set_y_ruby(RubyValue object, RubyValue y_value) {
        RxTilemap* tilemap = rgss_get_rb_data<RxTilemap>(object);
        int new_y = rb_parse_int(y_value);
        if (tilemap->tilemap_sprite8->offset_y != new_y) {
            RxTilemapSprite* sprite = tilemap->tilemap_sprite8;
            sprite->offset_y = new_y;
            (sprite->*(TilemapSpriteOffsetHook::orig_set_sprite_offset))(sprite->offset_x, sprite->offset_y);
        }
        if (tilemap->tilemap_spriteC->offset_y != new_y) {
            RxTilemapSprite* sprite = tilemap->tilemap_spriteC;
            sprite->offset_y = new_y;
            (sprite->*(TilemapSpriteOffsetHook::orig_set_sprite_offset))(sprite->offset_x, sprite->offset_y);
        }

        return y_value;
    }

    static RubyValue __cdecl rx_viewport_get_x_ruby(RubyValue object) {
        RxViewport* viewport = rgss_get_rb_data<RxViewport>(object);

        return rb_make_number(viewport->offset_x);
    }

    static RubyValue __cdecl rx_viewport_set_x_ruby(RubyValue object, RubyValue x_value) {
        RxViewport* viewport = rgss_get_rb_data<RxViewport>(object);
        int new_x = rb_parse_int(x_value);
        if (viewport->offset_x != new_x) {
            viewport->offset_x = new_x;
            (viewport->*(viewport->vftable->set_sprite_offset))(viewport->offset_x, viewport->offset_y);
        }

        return x_value;
    }

    static RubyValue __cdecl rx_viewport_get_y_ruby(RubyValue object) {
        RxViewport* viewport = rgss_get_rb_data<RxViewport>(object);

        return rb_make_number(viewport->offset_y);
    }

    static RubyValue __cdecl rx_viewport_set_y_ruby(RubyValue object, RubyValue y_value) {
        RxViewport* viewport = rgss_get_rb_data<RxViewport>(object);
        int new_y = rb_parse_int(y_value);
        if (viewport->offset_y != new_y) {
            viewport->offset_y = new_y;
            (viewport->*(viewport->vftable->set_sprite_offset))(viewport->offset_x, viewport->offset_y);
        }

        return y_value;
    }

    void apply_hrfix() {
        if (!mod_loader->get_config().is_hrfix_enabled()) {
            return;
        }

        hrfix_render_width = mod_loader->get_config().get_required_width();
        hrfix_render_height = mod_loader->get_config().get_required_height();

        // Patch for screen size
        mod_loader->patch_memory_as<int>(0x20F6, hrfix_render_width); // set width limit for resize_screen
        mod_loader->patch_memory_as<int>(0x2106, hrfix_render_height); // set heght limit for resize_screen

        mod_loader->patch_memory_as<int>(0x20FF, hrfix_render_width); // set new width for resize_screen if exceeds cap
        mod_loader->patch_memory_as<int>(0x210F, hrfix_render_height); // set new height for resize_screen if exceeds cap

        mod_loader->patch_memory_as<int>(0x1A5B, hrfix_render_width);
        mod_loader->patch_memory_as<int>(0x1A56, hrfix_render_height);

        mod_loader->patch_memory_as<int>(0x19AA, hrfix_render_width);
        mod_loader->patch_memory_as<int>(0x19A5, hrfix_render_height);

        mod_loader->patch_memory_as<int>(0x1C5E8, hrfix_render_width);
        mod_loader->patch_memory_as<int>(0x1C5E3, hrfix_render_height);

        mod_loader->patch_memory_as<int>(0x1F47C, hrfix_render_width);
        mod_loader->patch_memory_as<int>(0x1F477, hrfix_render_height);

        mod_loader->patch_memory_as<int>(0x10F94A, hrfix_render_width); // set new render chunk width
        mod_loader->patch_memory_as<char>(0x10F948, 41); // set new render chunk height

        mod_loader->patch_memory_as<int>(0x21204, hrfix_render_width + 32); // set default sprite width, +1 tile for seamless screen scroll
        mod_loader->patch_memory_as<int>(0x211FF, hrfix_render_height + 32); // set default sprite height, +1 tile for seamless screen scroll

        mod_loader->hook_method(tilemap_render_tiles, &RxTilemapSpriteHRFixHook::render_tilemap_tiles_hook, &RxTilemapSpriteHRFixHook::orig_render_tilemap_tiles);
        mod_loader->hook_method(surface_init_bitmap, &SurfaceHRFixHook::init_surface_bitmap_hook, &SurfaceHRFixHook::orig_init_surface_bitmap);
        //mod_loader->hook_method(set_sprite_offset, &SpriteHRFixHook::set_sprite_offset_hook, &SpriteHRFixHook::orig_set_sprite_offset);
        //mod_loader->hook_method(set_sprite_offset, &SpriteHRFixHook::set_rect_hook, &SpriteHRFixHook::orig_set_rect);

        // Patch for new RxTilemap field
        mod_loader->patch_memory(0x1521F, sizeof(RxPatchTilemap));
        mod_loader->hook_function(tilemap_initialize, TilemapMapIDPatch::tilemap_initialize_hook, &TilemapMapIDPatch::orig_tilemap_initialize);
        mod_loader->hook_function(init_rb_tilemap, TilemapMapIDPatch::init_rb_tilemap_hook, &TilemapMapIDPatch::orig_init_rb_tilemap);

        mod_loader->hook_api_function(L"user32.dll", "CreateWindowExW", create_window_ex_hook, &orig_CreateWindowExW);

        // Fix for transitions
        mod_loader->patch_memory_as<int>(0x10E6A7, hrfix_render_width);
        mod_loader->patch_memory_as<int>(0x10E6C4, hrfix_render_height);

        // enable fullscreen by key
        mod_loader->hook_method(input_update_keys, &RxInputHRFixHook::update_keys_hook, &RxInputHRFixHook::orig_update_keys);
        input_update_keys = static_cast<decltype(input_update_keys)>(&RxInputHRFixHook::update_keys_hook);

        mod_loader->hook_method(screen_resize_screen, &DisableFullscreenHook::resize_screen_hook, &DisableFullscreenHook::orig_resize_screen);

        // set default resolution
        mod_loader->add_postinit_handler([] {
            auto [adjusted_width, adjusted_height] = offset_screen_size(hrfix_render_width, hrfix_render_height);
            (mod_loader->get_game()->*game_frame_resize_screen)(adjusted_width, adjusted_height);
        });

        mod_loader->add_preinit_handler([] {
            RubyValue* tilemap_klass = mod_loader->at_base_offset_as<RubyValue*>(0x26A0B4);

            rb_define_method(*tilemap_klass, "x", rx_tilemap_get_x_ruby, 0);
            rb_define_method(*tilemap_klass, "x=", rx_tilemap_set_x_ruby, 1);
            rb_define_method(*tilemap_klass, "y", rx_tilemap_get_y_ruby, 0);
            rb_define_method(*tilemap_klass, "y=", rx_tilemap_set_y_ruby, 1);

            RubyValue* viewport_klass = mod_loader->at_base_offset_as<RubyValue*>(0x26A0D8);

            rb_define_method(*viewport_klass, "x", rx_viewport_get_x_ruby, 0);
            rb_define_method(*viewport_klass, "x=", rx_viewport_set_x_ruby, 1);
            rb_define_method(*viewport_klass, "y", rx_viewport_get_y_ruby, 0);
            rb_define_method(*viewport_klass, "y=", rx_viewport_set_y_ruby, 1);
        });

        SpriteVFTable* tilemap_sprite_vftable = mod_loader->at_base_offset_as<SpriteVFTable*>(0x1A91EC);
        TilemapSpriteOffsetHook::orig_set_sprite_offset = tilemap_sprite_vftable->set_sprite_offset;
        tilemap_sprite_vftable->set_sprite_offset = static_cast<decltype(SpriteVFTable::set_sprite_offset)>(&TilemapSpriteOffsetHook::set_sprite_offset_hook);

        mod_loader->log_info("Applied HRFix\n");
    }
};