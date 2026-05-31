#pragma once
#ifndef WIN32_MEAN_AND_LEAN
# define WIN32_MEAN_AND_LEAN
#endif
#include <Windows.h>
#include <string_view>

#define __cppobj
#define RM_CLASS __single_inheritance

namespace rm_modloader {

	struct RM_CLASS RxTilemap;
	struct RM_CLASS Screen;
	struct RM_CLASS Surface;
	struct RM_CLASS DrawLocal_DynamicDraw;
	struct RM_CLASS RxSprite;
	struct RM_CLASS Sprite;
	struct RM_CLASS RxFontList;
	struct RM_CLASS RxInput;
	struct RM_CLASS SurfaceSprite;
	struct RM_CLASS ImageLoader;
	struct RM_CLASS BIDImage;

	struct SpriteVFTable {
		void* (__thiscall Sprite::* destructor)(char a1);
		int(__thiscall Sprite::* unk4)(int a1);
		bool(__thiscall Sprite::* set_sprite_offset)(int x, int y);
		void(__thiscall Sprite::* unkC)(int a1);
		void(__thiscall Sprite::* unk10)(int a1);
		void(__thiscall Sprite::* unk14)(DWORD a1, DWORD a2);
		int(__thiscall Sprite::* set_render_rect)(RECT* rect);
		Sprite* (__thiscall Sprite::* set_ancestor)(Sprite* ancestor);
		void(__thiscall* Sprite::* unk20)();
		int(__thiscall* Sprite::* unk24)(Surface*, int);
		void(__thiscall* Sprite::* unk28)(int a1); // Almost every is empty function
		int(__thiscall* Sprite::* unk2C)(int, int);
		void(__thiscall* Sprite::* unk30)(RECT*);
	};

	struct ImageLoaderVFTable {
		void* (__thiscall ImageLoader::* destructor)(char a1);
		bool(__thiscall ImageLoader::* is_supported_data)(BYTE data[2048]);
		BIDImage* (__thiscall ImageLoader::* read_image)(BYTE* data); // data size?
	};

	static_assert(sizeof(SpriteVFTable::set_sprite_offset) == sizeof(void*));

	/* 23 */
	struct RM_CLASS Sprite
	{
		static constexpr std::string_view type_name = "class CNxSprite";

		SpriteVFTable* vftable;
		Sprite* ancestor;
		RECT rect;
		int offset_x;
		int offset_y;
		DWORD is_visible;
		RECT rect24;
		DWORD gap34[2];
		int offset_z;
		DWORD gap40[3];
		RECT rect4C;
		RECT rect5C;
		DWORD need_update_offset;
		DWORD sprite_id;
		DWORD need_update_rect;
		DWORD unk78;
		DWORD gap7C[2];
		Sprite** child_begin;
		Sprite** child_end;
	};

	struct RM_CLASS SurfaceSpriteVFTable : SpriteVFTable {

	};

	/* 30 */
	struct RM_CLASS SurfaceSprite : Sprite
	{
		static constexpr std::string_view type_name = "class CNxSurfaceSprite";

		DWORD gap8C[1];
		Surface* surface90;
		DWORD blend_type;
		DWORD gap94[5];
		Surface* surface;
		DWORD gapB0[6];
		DWORD opacity;
	};

	/* 16 */
	struct RM_CLASS RxTilemapSprite : SurfaceSprite
	{
		static constexpr std::string_view type_name = "class CRxTilemapSprite";

		RxTilemap* tilemap;
		DWORD unkD0;
	};

	/* 24 */
	struct RM_CLASS Window : Sprite
	{
		static constexpr std::string_view type_name = "class CNxWindow";

		DWORD gap8C[2];
		LRESULT(__stdcall* old_window_proc)(HWND, UINT, WPARAM, LPARAM);
		Surface* surface;
		HWND window_handle;
	};

	/* 22 */
	struct RM_CLASS Screen : Window
	{
		static constexpr std::string_view type_name = "class CNxScreen";

		DWORD gapA0[3];
		RECT window_rect;
		RECT rectBC;
		void* unkCC;
		DWORD gapD0[8];
	};

	/* 20 */
	struct RM_CLASS RxTilemap {
		DWORD vftable;
		Sprite* viewport;
		RxTilemapSprite* tilemap_sprite8;
		RxTilemapSprite* tilemap_spriteC;
		DWORD gap10[16384];
		Surface* tilesets_surfaces[9];
		int16_t* map_data;
		DWORD width;
		DWORD height;
		DWORD depth;
		DWORD gap10044[4];
		int16_t* flags;
		DWORD flags_count;
		DWORD unk5C;
		DWORD offset_x;
		DWORD offset_y;
		DWORD offset_x_tiles;
		DWORD offset_y_tiles;
		DWORD unk10070;
	};


	struct RM_CLASS RxPatchTilemap : RxTilemap {
		int map_id;
	};

	/* 21 */
	struct RM_CLASS GameFrame
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
		RxInput* input;
		RxFontList* font_list260;
		TIMECAPS time_caps264;
	};

	/* 25 */
	struct RM_CLASS BIDImage
	{
		DWORD vftable;
		DWORD gap4[1];
		BYTE* buffer_bits;
		BYTE* bits;
		DWORD gap10[3];
	};


	union SurfaceBitmapInfo
	{
		BITMAPINFO* bitmap;
		DWORD bit_count;
	};

	static_assert(sizeof(SurfaceBitmapInfo) == 4);
	static_assert(alignof(SurfaceBitmapInfo) == 4);

	/* 26 */
	struct RM_CLASS Surface
	{
		DWORD vftable;
		BIDImage image;
		SurfaceBitmapInfo info;
		DWORD custom_draw;
		DrawLocal_DynamicDraw* dynamic_draw;
		HBITMAP bitmap_handle;
		HDC dc;
		DWORD unk34;
		int left_offset;
		int top_offset;
		RECT rect;
		DWORD gap50[2];
	};

	/* 31 */
	struct __cppobj RM_CLASS RxSprite : SurfaceSprite
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

	enum class RxInputDirection {
		DownLeft = 1,
		Down = 2,
		DownRight = 3,
		Left = 4,
		// 5 unused
		Right = 6,
		UpLeft = 7,
		Up = 8,
		UpRight = 9
	};

	/* 36 */
	struct RM_CLASS RxInput
	{
		DWORD vftable;
		DWORD gap4[7];
		BYTE key_binds[17];
		BYTE immediate_current_keys[30]; // setted once when updating, then immediately clears
		BYTE current_keys[30]; // currently hold keys
		BYTE last_keys[30]; // last update holded keys
		BYTE unk88;
		DWORD gap8C[2];
		RxInputDirection dir4; // contains only even numbers, so doesn't count diagonal moves
		RxInputDirection dir8;
		DWORD unk9C;
	};


	/* 35 */
	struct RM_CLASS RxFontList
	{
		DWORD vftable;
		DWORD gap4[7];
	};

	/* 27 */
	struct RM_CLASS DrawLocal_DynamicDraw
	{
		DWORD vftable;
		DWORD unk4;
		RTL_CRITICAL_SECTION crit_sect8;
	};

	/* 28 */
	struct RM_CLASS DrawLocal_DynamicDraw8 : DrawLocal_DynamicDraw
	{
	};

	/* 29 */
	struct RM_CLASS DrawLocal_DynamicDraw32 : DrawLocal_DynamicDraw
	{
		DWORD unk20;
		DWORD unk24;
		DWORD unk28;
	};

	/* 31 */
	struct __cppobj RM_CLASS RxViewport : Sprite
	{
		static constexpr std::string_view type_name = "class CRxViewport";

		DWORD gap8C[13];
		DWORD color;
		DWORD gapC4[3];
	};

	/* 32 */
	struct RM_CLASS RxPlane : SurfaceSprite {
		static constexpr std::string_view type_name = "class CRxPlane";

		DWORD gapCC[3];
		double doubleD8;
		double doubleE0;
		DWORD gapC[10];

	};

	/* 33 */
	struct RM_CLASS ImageLoader {
		ImageLoaderVFTable* vftable;
	};

	/* 34 */
	struct RM_CLASS DrawLocal_ImageLoader {
		DWORD vftable;
		ImageLoader* image_loader;
	};

	struct RM_CLASS RxSurface : Surface {
		static constexpr std::string_view type_name = "class CRxSurface";

		DWORD unk58;
	};

	struct RM_CLASS RxBitmap {
		static constexpr std::string_view type_name = "class CRxBitmap";

		BYTE gap0[8];
		RxSurface* surface;
	};

	struct RM_CLASS File {
		DWORD vftable;
		HMMIO mm_io;
		DWORD gap4[7];
	};

	struct RM_CLASS RxMemoryFile : File {
		DWORD unk24;
	};

	struct RM_CLASS RepositoryFileInfo {
		DWORD offset;
		DWORD file_size;
		DWORD unk8;
		char filename[MAX_PATH];
	};

	struct RM_CLASS FileRepository {
		DWORD unk0;
		DWORD unk4;
		DWORD unk8;
		RepositoryFileInfo* first_file;
		RepositoryFileInfo* last_file;
		DWORD unk14;
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
	static_assert(sizeof(ImageLoader) == 0x4);
	static_assert(sizeof(DrawLocal_ImageLoader) == 0x8);
	static_assert(sizeof(RxInput) == 0xA0);
	static_assert(sizeof(RxBitmap) == 0xC);
	static_assert(sizeof(File) == 0x24);
	static_assert(sizeof(RxMemoryFile) == 0x28);
	static_assert(sizeof(RepositoryFileInfo) == 0x110);
	static_assert(sizeof(FileRepository) == 0x18);

};

#undef __cppobj
#undef RM_CLASS
