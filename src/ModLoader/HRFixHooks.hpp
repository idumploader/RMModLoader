#pragma once
#include "RMClasses.hpp"

namespace rm_modloader {

    extern int hrfix_render_width;
    extern int hrfix_render_height;

    /**
     * This hooks add new field to RxTilemap (map_id) and registers it's setted to ruby
     */
    struct TilemapMapIDPatch {
        static int(__cdecl* orig_tilemap_initialize)(int a1, int a2, void* a3);
        static void(__cdecl* orig_init_rb_tilemap)();

        static int __cdecl tilemap_initialize_hook(int a1, int a2, void* a3);
        static void __cdecl init_rb_tilemap_hook();

        static int __cdecl patch_tilemap_set_map_id(void* ruby_data, int map_id_object);
    };

    /**
     * This hook expands background tilemap size to properly render on larger screens.
     * By default it's limited to 16x21 tiles
     */
    struct RxTilemapSpriteHRFixHook : RxTilemapSprite {
        static int(__thiscall RxTilemapSprite::* orig_render_tilemap_tiles)(Surface* surf, RECT* rect);

        int __thiscall render_tilemap_tiles_hook(Surface* surf, RECT* in_rect);
    };

    /**
     * This hook increases fps by expanding surface sprite render chunk size
     */
    struct SurfaceHRFixHook : Surface {
        static int(__thiscall Surface::* orig_init_surface_bitmap)(int width, int height);

        int __thiscall init_surface_bitmap_hook(int width, int height);
    };

    struct SpriteHRFixHook : Sprite {
        static int(__thiscall Sprite::* orig_set_sprite_offset)(int x, int y);
        static int(__thiscall Sprite::* orig_set_rect)(RECT* new_rect);

        static int current_map_width;
        static int current_map_height;

        int __thiscall set_sprite_offset_hook(int x, int y);

        int __thiscall set_rect_hook(RECT* new_rect);
    };

    extern void apply_hrfix();
}