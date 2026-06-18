#pragma once
#include "RMClasses.hpp"
#include "Ruby.hpp"

#include <filesystem>

namespace rm_modloader {

    struct StartupScriptsString {
        WORD unk0;
        WCHAR buffer[ANYSIZE_ARRAY];
    };

    // --- RGSS module & global state ---
    extern HMODULE rgss_module;
    extern GameFrame** rgss_game;
    extern FileRepository* file_repository;

    inline GameFrame* get_rgss_game() {
        return *rgss_game;
    }

    // --- RPG Maker / RGSS engine: class methods, engine entry points, offset pointers ---
    extern int(__thiscall Sprite::* set_sprite_offset)(int x, int y);
    extern int(__thiscall Sprite::* set_rect)(RECT* new_rect);

    extern int(__thiscall Surface::* surface_init_bitmap)(int width, int height);
    extern int(__thiscall RxTilemapSprite::* tilemap_render_tiles)(Surface* surf, RECT* rect);

    extern int(__thiscall GameFrame::* game_frame_resize_screen)(int width, int height);
    extern int(__thiscall Screen::* screen_resize_screen)(int width, int height, bool is_fullscreen);

    extern int(FileRepository::* file_repository_file_count)();
    extern RepositoryFileInfo*(FileRepository::* file_repository_file_at_index)(int index);

    extern RxMemoryFile* (__cdecl* read_into_rx_memory_file)(const char* path);
    extern RxMemoryFile* (RxMemoryFile::* rx_memory_file_dtx)(bool is_delete);

    extern RxInput* (__thiscall RxInput::* input_update_keys)();
    // Despite the rb_ name, this is an RGSS RxInput helper (key index <-> Ruby symbol), not an MRI function.
    extern int(__cdecl* get_rb_key_symbol_index)(RubyValue symbol_value);

    extern RubyValue(__cdecl* tilemap_initialize)(RubyValue self, int a2, void* a3);
    extern RubyValue(__cdecl* init_rb_tilemap)(RubyValue self, int a2, void* a3);
    extern RubyValue(__cdecl* tilemap_bitmaps)(RubyValue self);

    // RGSS engine entry points (hooked) and class objects
    extern RubyValue(__cdecl* load_data)(RubyValue self, RubyValue filename);
    extern int(__cdecl* startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* rgss3a_filepath);
    extern RubyValue* rx_bitmap_class;

    // --- Ruby (MRI) runtime: functions, allocators, class & exception objects ---
    extern RubyValue(__cdecl* rb_str_new_cstr)(const char* ptr);
    extern RubyValue(__cdecl* rb_str_new)(const char* ptr, long len);
    extern RubyValue(__cdecl* rb_define_module)(const char* name);
    extern RubyValue(__cdecl* rb_define_function)(const char* name, void* func, int arg_count);
    extern RubyValue(__cdecl* rb_define_class)(const char* name, RubyValue base);
    extern RubyValue(__cdecl* rb_define_singleton_method)(RubyValue object, const char* name, void* func, int arg_count);
    extern RubyValue(__cdecl* rb_define_method)(RubyValue object, const char* name, void* func, int arg_count);
    extern RubyValue(__cdecl* rb_define_alloc_func)(RubyValue object, RubyValue(__cdecl* func)(RubyValue));
    extern int(__cdecl* rb_parse_int)(RubyValue object);
    extern const char* (__cdecl* rb_get_string_data)(RubyValue* rb_string);
    extern RubyValue(__cdecl* eval_rb_cstr)(const char* script, const char* script_name, int* error_code);
    extern RubyValue(__cdecl* eval_rb_cstr_noerr)(const char* script);
    extern RubyValue(__cdecl* rb_funcall)(RubyValue recv, RubyID mid, int n, ...);
    /// noreturn
    extern void(__cdecl* rb_raise)(RubyValue exc_class, const char* fmt, ...);
    extern int(__cdecl* get_rb_error_string)(WCHAR* error_buf, size_t buf_size, int*);

    extern RubyValue(__cdecl* rb_big_new)(int len, bool is_positive);
    extern void*(__cdecl* alloc_rb_rdata)(size_t size);
    extern RubyValue(__cdecl* make_rb_rdata)(RubyValue klass, void* data, void(__cdecl* dmark)(void*), void(__cdecl* dfree)(void*));

    extern RubyValue(__cdecl* rb_ary_new)();
    extern RubyValue(__cdecl* rb_ary_new2)(long capa);
    extern RubyValue(__cdecl* rb_ary_new4)(long n, const RubyValue* elts);
    extern int(__cdecl* rb_ary_push)(RubyValue arr, RubyValue value);

    extern void(__cdecl* rgss_free)(void* block);

    extern RubyValue* ruby_error_arg_error;
    extern RubyValue* ruby_c_object;
    extern RubyValue* ruby_c_bignum;

    /**
     * Loads the RGSS runtime DLL at the given path and resolves all global
     * function and method pointers from it.
     * @param rgss_dll_path Path to the RGSS runtime DLL (e.g. System\RGSS301.dll)
     * @throws std::runtime_error if the DLL fails to load
     */
    extern void init_functionset(const std::filesystem::path& rgss_dll_path);

};