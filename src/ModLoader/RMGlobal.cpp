#include "RMGlobal.hpp"
#include "Hook.hpp"

#include <stdexcept>

namespace rm_modloader {

    HMODULE rgss_module = nullptr;
    GameFrame** rgss_game = nullptr;

    int(__thiscall Sprite::* set_sprite_offset)(int x, int y) = nullptr;
    int(__thiscall Sprite::* set_rect)(RECT* new_rect) = nullptr;

    int(__thiscall Surface::* surface_init_bitmap)(int width, int height) = nullptr;
    int(__thiscall RxTilemapSprite::* tilemap_render_tiles)(Surface* surf, RECT* rect) = nullptr;

    int(__thiscall GameFrame::* game_frame_resize_screen)(int width, int height) = nullptr;

    RxInput*(__thiscall RxInput::* input_update_keys)() = nullptr;

    RubyValue(__cdecl* tilemap_initialize)(RubyValue self, int a2, void* a3) = nullptr;
    RubyValue(__cdecl* init_rb_tilemap)(RubyValue self, int a2, void* a3) = nullptr;
    RubyValue(__cdecl* tilemap_bitmaps)(RubyValue self) = nullptr;

    RubyValue(__cdecl* rb_str_new_cstr)(const char* ptr) = nullptr;
    RubyValue(__cdecl* rb_define_module)(const char* name) = nullptr;
    RubyValue(__cdecl* rb_define_function)(const char* name, void* func, int arg_count) = nullptr;
    RubyValue(__cdecl* rb_define_class)(const char* name, RubyValue base) = nullptr;
    RubyValue(__cdecl* rb_define_singleton_method)(RubyValue object, const char* name, void* func, int arg_count) = nullptr;
    RubyValue(__cdecl* rb_define_method)(RubyValue object, const char* name, void* func, int arg_count) = nullptr;
    int(__cdecl* rb_parse_int)(RubyValue object) = nullptr;
    const char* (__cdecl* rb_get_string_data)(RubyValue rb_string) = nullptr;
    RubyValue(__cdecl* eval_rb_cstr)(const char* script, BYTE* a2, int* error_code) = nullptr;
    RubyValue(__cdecl* eval_rb_cstr_noerr)(const char* script) = nullptr;
    int(__cdecl* get_rb_error_string)(WCHAR* error_buf, size_t buf_size, int*) = nullptr;

    int(__cdecl* load_data)(int self, int rb_filename) = nullptr;
    int(__cdecl* startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* rgss3a_filepath) = nullptr;

    int(__cdecl* get_rb_key_symbol_index)(RubyValue symbol_value) = nullptr;

    void init_functionset() {
        rgss_module = LoadLibrary(TEXT("System\\RGSS301.dll"));
        if (rgss_module == nullptr) {
            throw std::runtime_error("Failed to get RGSS301.dll");
        }
        rgss_game = at_offset<GameFrame**>(rgss_module, 0x25EB00);

        rb_define_method = at_offset<decltype(rb_define_method)>(rgss_module, 0x5EF70);
        rb_parse_int = at_offset<decltype(rb_parse_int)>(rgss_module, 0x15B40);
        rb_get_string_data = at_offset<decltype(rb_get_string_data)>(rgss_module, 0x37CA0);
        eval_rb_cstr = at_offset<decltype(eval_rb_cstr)>(rgss_module, 0x0C5B0);
        eval_rb_cstr_noerr = at_offset<decltype(eval_rb_cstr_noerr)>(rgss_module, 0xC600);
        get_rb_error_string = at_offset<decltype(get_rb_error_string)>(rgss_module, 0xD3E0);
        tilemap_initialize = at_offset<decltype(tilemap_initialize)>(rgss_module, 0x15180);
        init_rb_tilemap = at_offset<decltype(init_rb_tilemap)>(rgss_module, 0x14E00);

        rb_str_new_cstr = at_offset<decltype(rb_str_new_cstr)>(rgss_module, 0x36570);
        rb_define_module = at_offset<decltype(rb_define_module)>(rgss_module, 0x5E990);
        rb_define_function = at_offset<decltype(rb_define_function)>(rgss_module, 0x5F270);
        rb_define_class = at_offset<decltype(rb_define_class)>(rgss_module, 0x5E740);
        rb_define_singleton_method = at_offset<decltype(rb_define_singleton_method)>(rgss_module, 0x5F1E0);
        tilemap_bitmaps = at_offset<decltype(tilemap_bitmaps)>(rgss_module, 0x15520);
        tilemap_render_tiles = at_offset<decltype(tilemap_render_tiles)>(rgss_module, 0x21D40);
        game_frame_resize_screen = at_offset<decltype(game_frame_resize_screen)>(rgss_module, 0x20D0);
        surface_init_bitmap = at_offset<decltype(surface_init_bitmap)>(rgss_module, 0x10B3B0);
        input_update_keys = at_offset<decltype(input_update_keys)>(rgss_module, 0x1B4D0);
        set_sprite_offset = at_offset<decltype(set_sprite_offset)>(rgss_module, 0x110F40);
        set_rect = at_offset<decltype(set_rect)>(rgss_module, 0x110FF0);

        load_data = at_offset<decltype(load_data)>(rgss_module, 0xCDE0);
        startup_scripts = at_offset<decltype(startup_scripts)>(rgss_module, 0xEA50);

        get_rb_key_symbol_index = at_offset<decltype(get_rb_key_symbol_index)>(rgss_module, 0x0C340);
    }

}