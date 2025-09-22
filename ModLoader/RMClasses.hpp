#pragma once
#ifndef WIN32_MEAN_AND_LEAN
# define WIN32_MEAN_AND_LEAN
#endif
#include <Windows.h>
#include <string_view>

#define __cppobj

// TODO: change
#pragma pointers_to_members(full_generality, single_inheritance)

namespace rm_modloader {

	struct RxTilemap;
	struct Screen;
	struct Surface;
	struct DrawLocal_DynamicDraw;
	struct RxSprite;
	struct Sprite;
	struct RxFontList;
	struct RxInput;
	struct SurfaceSprite;

	struct SpriteVFTable {
		void* (__thiscall Sprite::* destructor)(char a1);
		int(__thiscall Sprite::* unk4)(int a1);
		bool(__thiscall Sprite::* set_sprite_offset)(int x, int y);
		void(__thiscall Sprite::* unkC)(int a1);
		void(__thiscall Sprite::* unk10)(int a1);
		void(__thiscall Sprite::* unk14)(DWORD a1, DWORD a2);
		int(__thiscall Sprite::* set_render_rect)(RECT* rect);
		Sprite* (__thiscall Sprite::* set_ancestor)(Sprite* ancestor);
		void(__thiscall* unk20)();
		int(__thiscall* unk24)(Surface*, int);
		void(__thiscall* unk28)(int a1); // Almost every is empty function
		int(__thiscall* unk2C)(int, int);
		void(__thiscall* unk30)(RECT*);
	};

	static_assert(sizeof(SpriteVFTable::set_sprite_offset) == 0x4);

	/* 23 */
	struct Sprite
	{
		static constexpr std::string_view type_name = "class CNxSprite";

		SpriteVFTable* vftable;
		Sprite* ancestor;
		RECT rect;
		int offset_x;
		int offset_y;
		DWORD is_visible;
		RECT rect24;
		DWORD gap34[6];
		RECT rect4C;
		RECT rect5C;
		DWORD M_need_update_offset;
		DWORD sprite_id;
		DWORD M_need_update_rect;
		DWORD unk78;
		DWORD gap7C[2];
		Sprite** M_child_begin;
		Sprite** M_child_end;
	};

	struct SurfaceSpriteVFTable : SpriteVFTable {

	};

	/* 30 */
	struct SurfaceSprite : Sprite
	{
		static constexpr std::string_view type_name = "class CNxSurfaceSprite";

		DWORD gap94[8];
		Surface* surface;
		DWORD gapB0[7];
	};



	/* 16 */
	struct RxTilemapSprite : SurfaceSprite
	{
		static constexpr std::string_view type_name = "class CRxTilemapSprite";

		RxTilemap* tilemap;
		DWORD unkD0;
	};

	/* 24 */
	struct Window : Sprite
	{
		static constexpr std::string_view type_name = "class CNxWindow";

		DWORD gap8C[2];
		LRESULT(__stdcall* old_window_proc)(HWND, UINT, WPARAM, LPARAM);
		Surface* surface;
		HWND window_handle;
	};

	/* 22 */
	struct Screen : Window
	{
		static constexpr std::string_view type_name = "class CNxScreen";

		DWORD gapA0[3];
		RECT window_rect;
		RECT rectBC;
		void* unkCC;
		DWORD gapD0[8];
	};

	/* 20 */
	struct RxTilemap
	{
		DWORD vftable;
		Sprite* ancestor;
		RxTilemapSprite* tilemap_sprite8;
		RxTilemapSprite* tilemap_spriteC;
		DWORD gap10[16384];
		DWORD gap10010[10];
		DWORD width;
		DWORD height;
		DWORD dword10040;
		DWORD gap10044[7];
		DWORD offset_x;
		DWORD offset_y;
		DWORD offset_x_tiles;
		DWORD offset_y_tiles;
		DWORD unk10070;
	};

	struct RxPatchTilemap : RxTilemap {
		int map_id;
	};

	/* 21 */
	struct GameFrame
	{
		static constexpr std::string_view type_name = "class CGameFrame";

		DWORD vftable;
		DWORD gap4[1];
		HWND window_handle;
		WCHAR window_title[256];
		DWORD gap20C[2];
		DWORD required_fps;
		DWORD unk214;
		BOOL window_is_active;
		DWORD last_frame_time_ms;
		DWORD updates_per_second;
		DWORD frames_count;
		DWORD frames_before_update;
		DWORD last_frames_count;
		DWORD show_fps_enabled;
		DWORD last_mesage_ms;
		DWORD gap23C[2];
		Screen* screen;
		Surface* surface248;
		Surface* surface24C;
		RxSprite* sprite250;
		Surface* surface254;
		RxSprite* sprite258;
		RxInput* input25C;
		RxFontList* font_list260;
		TIMECAPS time_caps264;
	};

	/* 25 */
	struct BIDImage
	{
		DWORD vftable;
		DWORD gap4[6];
	};

	/* 26 */
	struct Surface
	{
		DWORD vftable;
		BIDImage image4;
		DWORD draw_bit_count;
		DWORD draw_vftable;
		DrawLocal_DynamicDraw* dynamic_draw;
		DWORD gap2C[5];
		RECT rect;
		DWORD gap50[2];
	};

	/* 31 */
	struct __cppobj RxSprite : SurfaceSprite
	{
		static constexpr std::string_view type_name = "class CRxSprite";

		RECT src_rect;
		POINT coord;
		POINT origin;
		double zoom_x;
		double zoom_y;
		double angle;
		DWORD wave_amp;
		DWORD wave_length;
		DWORD wave_speed;
		DWORD unk114;
		double wave_phase;
		BOOL is_mirror;
		DWORD gap124[6];
		DWORD color;
		DWORD gap140[96];
	};


	/* 36 */
	struct RxInput
	{
		DWORD vftable;
		DWORD gap4[39];
	};

	/* 35 */
	struct RxFontList
	{
		DWORD vftable;
		DWORD gap4[7];
	};

	/* 27 */
	struct DrawLocal_DynamicDraw
	{
		DWORD vftable;
		DWORD unk4;
		RTL_CRITICAL_SECTION crit_sect8;
	};

	/* 28 */
	struct DrawLocal_DynamicDraw8 : DrawLocal_DynamicDraw
	{
	};

	/* 29 */
	struct DrawLocal_DynamicDraw32 : DrawLocal_DynamicDraw
	{
		DWORD unk20;
		DWORD unk24;
		DWORD unk28;
	};

	/* 30 */
	struct __cppobj RxViewport : Sprite
	{
		static constexpr std::string_view type_name = "class CRxViewport";

		DWORD gap7C[17];
	};

	struct RxPlane : SurfaceSprite {
		static constexpr std::string_view type_name = "class CRxPlane";

		DWORD gapCC[3];
		double doubleD8;
		double doubleE0;
		DWORD gapC[10];

	};

	// TODO: change
	//#pragma pointers_to_members(best_case)

	static_assert(sizeof(Screen) == 0xF0);
	static_assert(sizeof(RxViewport) == 0xD0);
	static_assert(sizeof(SurfaceSprite) == 0xCC);
	static_assert(sizeof(RxSprite) == 0x2C0);
	static_assert(sizeof(Surface) == 0x58);
	static_assert(sizeof(Window) == 0xA0);
	static_assert(sizeof(RxTilemapSprite) == 0xD4);
	static_assert(sizeof(RxTilemap) == 0x10074);
	static_assert(sizeof(RxPlane) == 0x110);

};
#undef __cppobj