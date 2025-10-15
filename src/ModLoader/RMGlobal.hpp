#pragma once
#include "RMClasses.hpp"

namespace rm_modloader {

    struct StartupScriptsString {
        WORD unk0;
        WCHAR buffer[ANYSIZE_ARRAY];
    };

    extern HMODULE rgss_module;
    extern GameFrame** rgss_game;

    inline GameFrame* get_rgss_game() {
        return *rgss_game;
    }

    using RubyValue = int;

    constexpr RubyValue ruby_false = 0;
    constexpr RubyValue ruby_true = 2;
    constexpr RubyValue ruby_nil = 4;

    extern int(__thiscall Sprite::* set_sprite_offset)(int x, int y);
    extern int(__thiscall Sprite::* set_rect)(RECT* new_rect);

    extern int(__thiscall Surface::* surface_init_bitmap)(int width, int height);
    extern int(__thiscall RxTilemapSprite::* tilemap_render_tiles)(Surface* surf, RECT* rect);

    extern RubyValue(__cdecl* tilemap_initialize)(RubyValue self, int a2, void* a3);
    extern RubyValue(__cdecl* init_rb_tilemap)(RubyValue self, int a2, void* a3);
    extern RubyValue(__cdecl* tilemap_bitmaps)(RubyValue self);

    extern RubyValue(__cdecl* rb_get_module)(const char* name);
    extern RubyValue(__cdecl* rb_register_module_method)(RubyValue object, const char* name, void* func, int arg_count);
    extern RubyValue(__cdecl* rb_register_method)(RubyValue object, const char* name, void* func, int arg_count);
    extern int(__cdecl* rb_parse_int)(RubyValue object);
    extern const char* (__cdecl* rb_get_string_data)(RubyValue rb_string);
    extern RubyValue(__cdecl* eval_rb_cstr)(const char* script, BYTE* a2, int* error_code);
    extern RubyValue(__cdecl* eval_rb_cstr_noerr)(const char* script);
    extern int(__cdecl* get_rb_error_string)(WCHAR* error_buf, size_t buf_size, int*);

    extern int(__cdecl* load_data)(int self, int rb_filename);
    extern int(__cdecl* startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* rgss3a_filepath);

    /**
     * Initializes all global functions and method pointers
     */
    extern void init_functionset();

};