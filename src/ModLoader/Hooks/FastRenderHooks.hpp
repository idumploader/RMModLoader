#pragma once
#include "../RMClasses.hpp"

namespace rm_modloader {
	struct ScreenFastRenderHook : Screen {
		static int(__thiscall Screen::* orig_update_screen)(int a1, int a2);

		int __thiscall update_screen_hook(int a1, int a2);
	};

	struct RxTilemapFRHook : RxTilemap {
		static int(__thiscall RxTilemap::* orig_update_data)(WORD* map_data, DWORD width, DWORD height, DWORD depth);
		static int(__thiscall RxTilemap::* orig_set_surface_at)(unsigned int index, Surface* surface);
		static RxTilemap* (__thiscall RxTilemap::* orig_tilemap_destructor)(char a1);

		int __thiscall update_data_hook(WORD* map_data, DWORD width, DWORD height, DWORD depth);
		int __thiscall set_surface_at_hook(unsigned int index, Surface* surface);

		RxTilemap* __thiscall tilemap_destructor_hook(char a1);
	};

	struct RxSpriteFRHook : RxSprite {
		static RxSprite*(__thiscall RxSprite::* orig_constructor)(Sprite* ancestor);
		static RxSprite*(__thiscall RxSprite::* orig_destructor)(char a1);
		static Surface* (__thiscall RxSprite::* orig_set_surface)(Surface* surface, RECT* src_rect);
		static int(__thiscall RxSprite::* orig_update_data)();

		static int(__thiscall RxSprite::* orig_flash)(DWORD color, int duration);

		RxSprite* __thiscall constructor_hook(Sprite* ancestor);
		RxSprite* __thiscall destructor_hook(char a1);

		Surface* __thiscall set_surface_hook(Surface* surface, RECT* src_rect);
		int __thiscall update_data_hook();

		int __thiscall flash_hook(DWORD color, int duration);
	};

	extern void apply_fast_render();
};