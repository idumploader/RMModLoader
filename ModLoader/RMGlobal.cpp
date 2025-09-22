#include "RMGlobal.hpp"
#include "Hook.hpp"

namespace rm_modloader {

    HMODULE rgss_module = nullptr;
    GameFrame** rgss_game = nullptr;

    int(__thiscall Sprite::* set_sprite_offset)(int x, int y) = nullptr;
    int(__thiscall Sprite::* set_rect)(RECT* new_rect) = nullptr;

    int(__thiscall Surface::* surface_init_bitmap)(int width, int height) = nullptr;
    int(__thiscall RxTilemapSprite::* tilemap_render_tiles)(Surface* surf, RECT* rect) = nullptr;

    int(__cdecl* tilemap_initialize)(int self, int a2, void* a3) = nullptr;
    int(__cdecl* init_rb_tilemap)(int self, int a2, void* a3) = nullptr;
    unsigned int(__cdecl* tilemap_bitmaps)(int a1) = nullptr;

    int(__cdecl* rb_register_method)(void* object, const char* name, void* func, int arg_count) = nullptr;
    int(__cdecl* rb_parse_int)(int object) = nullptr;
    const char* (__cdecl* rb_get_string_data)(int* prb_string) = nullptr;
    int(__cdecl* eval_rb_cstr)(const char* script, BYTE* a2, int* error_code) = nullptr;
    int(__cdecl* eval_rb_cstr_noerr)(const char* script) = nullptr;
    int(__cdecl* get_rb_error_string)(WCHAR* error_buf, size_t buf_size, int*) = nullptr;

    int(__cdecl* load_data)(int self, int rb_filename) = nullptr;
    int(__cdecl* startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* rgss3a_filepath) = nullptr;

    void init_functionset() {
        rb_register_method = at_offset<decltype(rb_register_method)>(rgss_module, 0x5EF70);
        rb_parse_int = at_offset<decltype(rb_parse_int)>(rgss_module, 0x15B40);
        rb_get_string_data = at_offset<decltype(rb_get_string_data)>(rgss_module, 0x37CA0);
        eval_rb_cstr = at_offset<decltype(eval_rb_cstr)>(rgss_module, 0x0C5B0);
        eval_rb_cstr_noerr = at_offset<decltype(eval_rb_cstr_noerr)>(rgss_module, 0xC600);
        get_rb_error_string = at_offset<decltype(get_rb_error_string)>(rgss_module, 0xD3E0);
        tilemap_initialize = at_offset<decltype(tilemap_initialize)>(rgss_module, 0x15180);
        init_rb_tilemap = at_offset<decltype(init_rb_tilemap)>(rgss_module, 0x14E00);

        tilemap_bitmaps = at_offset<decltype(tilemap_bitmaps)>(rgss_module, 0x15520);
        tilemap_render_tiles = at_offset<decltype(tilemap_render_tiles)>(rgss_module, 0x21D40);
        surface_init_bitmap = at_offset<decltype(surface_init_bitmap)>(rgss_module, 0x10B3B0);
        set_sprite_offset = at_offset<decltype(set_sprite_offset)>(rgss_module, 0x110F40);
        set_rect = at_offset<decltype(set_rect)>(rgss_module, 0x110FF0);

        load_data = at_offset<decltype(load_data)>(rgss_module, 0xCDE0);
        startup_scripts = at_offset<decltype(startup_scripts)>(rgss_module, 0xEA50);
    }

}