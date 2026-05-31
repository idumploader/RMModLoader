#include "FakeRenderer.hpp"

#include "GdiRender.hpp"
#include "Logger.hpp"
#include "SteamLoader.hpp"

#include "../Steam/steam_api.h"  // ISteamScreenshots::WriteScreenshot

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <format>
#include <unordered_map>

using rm_modloader::Logger;

// Defined in SteamOverlay.cpp — даёт нам runtime-загруженный SteamFns
// (через него SteamScreenshots()-аналог).
extern const SteamFns& GetSteamFns();

// HWND host'а — хранится здесь, выставляется InitGDIFakeRenderer'ом.
// Используется Handler_GetHWND / Handler_GetOutputBounds / Handler_ScreenSize
// чтобы overlay правильно мапил cursor и считал screen-абс координаты.
static HWND s_hwnd = nullptr;

// ---------------------------------------------------------------
// Версионный layout. Build 2026-05-09 — see project_renderer_vtables.md
// в memory для деталей реверса.
// ---------------------------------------------------------------
const VtableLayout kLayout_2026_05 = {
	.total_slots              = 28,
	.slot_dtor                = 0,
	.slot_FrameStart          = 1,
	.slot_DrawTexturedRect    = 3,
	.slot_LoadTexture         = 4,
	.slot_SetChromePaintSource = 5,
	.slot_SharedTexA          = 6,
	.slot_SharedTexB          = 8,
	.slot_PostFrame           = 9,
	.slot_ScreenSize          = 11,
	.slot_DeleteTexture       = 12,
	.slot_ScreenshotComplete  = 13,
	.slot_CaptureScreenshot   = 14,
	.slot_GetHWND             = 20,
	.slot_RetFour             = 23,
	.slot_GetOutputBounds     = 26,
	.slot_GetClassName        = 27,
};

// ---------------------------------------------------------------
// Runtime vtable storage. Шарится между всеми GDIFakeRenderer instance'ами
// (которых у нас всё равно один). Запас на 64 слота на случай если в
// будущей версии DLL добавятся ещё.
// ---------------------------------------------------------------
static void* g_vtable_storage[64] = {};

// ---------------------------------------------------------------
// Handler functions. __fastcall(this, dummy_edx, ...args) даёт ABI-совместимое
// с __thiscall поведение для x86: ecx=this, edx ignored, args на стеке,
// callee cleans. Компилятор сам генерит правильный `ret N*4` по подсчёту
// stack-аргументов.
// ---------------------------------------------------------------

// Slot 0: scalar-deleting destructor. Принимает delete-flag (char) на стеке.
// Steam в нашем сценарии не удаляет renderer, но vtable[0] всё равно должен
// быть валидным `ret 4`. Используем DLL-thunk nullsub_2.
// (Поэтому Handler'а для dtor нет — слот указывает на DLL'евый thunk.)

extern "C" void __fastcall Handler_FrameStart(GDIFakeRenderer* /*ecx*/, void* /*edx*/) {
}

// Slot 3: DrawTexturedRect. 13 dword args.
// Реверс case 3 в M_ProcessPaintStream:
//   - Dispatcher читает 52 байта (13 dword) из paint_stream'а
//   - Перетасовывает порядок при push'е в vtable[3]:
//     packet[0..7] (rect+UV)         → args 0..7
//     packet[12] (textureID)         → arg 8     (последний dword пакета)
//     packet[9..11] (color/gradient) → args 9..11
//     packet[8] (mystery float)      → arg 12    (середина пакета)
extern "C" void __fastcall Handler_DrawTexturedRect(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	int32_t  x0, int32_t y0, int32_t x1, int32_t y1,    // 0..3
	float    u0, float v0, float u1, float v1,           // 4..7
	uint32_t textureID,                                   // 8
	uint32_t color_start, uint32_t /*color_end*/,         // 9..10
	uint32_t /*gradient*/,                                // 11
	float    /*extra_float*/)                             // 12
{
	const int dw = x1 - x0;
	const int dh = y1 - y0;
	if (dw <= 0 || dh <= 0) return;
	Tex_DrawRect(textureID, x0, y0, dw, dh, u0, v0, u1, v1, color_start);
}

// Slot 4: LoadTexture. 11 dword args.
// Реверс case 1 в M_ProcessPaintStream (см. FakeRenderer.hpp историю)
extern "C" void __fastcall Handler_LoadTexture(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	uint32_t textureID,
	uint32_t /*isPartialUpdate*/,
	uint32_t update_x,
	uint32_t update_y,
	uint32_t width,
	uint32_t height,
	uint32_t /*pixelDataSize*/,
	void*    pixelBuf,
	uint32_t /*format*/,
	uint32_t /*stride*/,
	uint8_t* outOwns)
{
	Tex_LoadOrUpdate(textureID, update_x, update_y, width, height, pixelBuf);
	if (outOwns) *outOwns = 0;  // dispatcher сам free()'нёт pixelBuf
}

// Slot 5: SetChromePaintSource (моё название). 2 args. Зовётся из
// sub_100A35E0 после успешного открытия Chrome paint buffer'а — передаёт
// pointer на shared-texture metadata + handle. Реально для нашего GDI-host'а
// мы не используем chrome paint buffers (это для CEF/steamwebhelper), но
// слот ОБЯЗАН иметь правильную арность чтобы стек чистился.
// Chrome paint buffer struct passed as arg1 в slot 5 (наш реверс):
//   [+0]  void*    mapped_pixels    — указатель на shared mem (MapViewOfFile result)
//   [+4]  void*    vtable_or_magic  — стабильный, не используем
//   [+8]  HANDLE   file_mapping     — handle на shared mem
//   [+12] int      flag0            — 0
//   [+16] int      state            — обычно -1 (sentinel)
//   [+20] int      width
//   [+24] int      height
//
// Layout shared region (size = 12*W*H + 52):
//   [0           .. 4*W*H)     slot 0 pixels (BGRA8)
//   [4*W*H       .. 8*W*H)     slot 1 pixels
//   [8*W*H       .. 12*W*H)    slot 2 pixels
//   [12*W*H      .. 12*W*H+48) 3 × 16-byte slot metadata (dirty rect)
//   [12*W*H+48   .. +52)       atomic sync (биты 2-3 = producer's last slot)
//
// Mirror'им логику COverlayGLRenderer::slot5 (sub_10086490): атомарно вычитываем
// producer's current slot, копируем пиксели оттуда в наш кэш.
struct ChromePaintBufDesc {
	void*    mapped_pixels;
	void*    vtable_or_magic;
	uint32_t handle;
	uint32_t flag0;
	int32_t  state;
	int32_t  width;
	int32_t  height;
};

extern "C" void __fastcall Handler_SetChromePaintSource(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	uint32_t arg1_paint_buf_struct, uint32_t arg2_textureID)
{
	if (!arg1_paint_buf_struct) return;
	const auto* desc = (const ChromePaintBufDesc*)(uintptr_t)arg1_paint_buf_struct;
	auto* mapped = (uint8_t*)desc->mapped_pixels;
	if (!mapped) return;
	const int W = desc->width;
	const int H = desc->height;
	if (W <= 0 || H <= 0 || W > 8192 || H > 8192) return;

	// Triple-buffer atomic — биты 2-3 = последний slot записанный producer'ом.
	const size_t slot_bytes = (size_t)W * H * 4;
	volatile long* sync = (volatile long*)(mapped + 3 * slot_bytes + 48);
	const long s = *sync;
	int slot = (s >> 2) & 3;
	if (slot >= 3) slot = 0;

	const uint8_t* pixels = mapped + (size_t)slot * slot_bytes;
	Tex_LoadOrUpdate(arg2_textureID, 0, 0, (uint32_t)W, (uint32_t)H, pixels);
}

// Slot 6: SharedTexA. Case 17 первая ветка (texture УЖЕ есть в renderer'е,
// shared mem не несёт новых пикселей). 15 args, ret 60. Имена аргументов
// — гипотеза по аналогии со slot 3 (DrawTexturedRect):
//   args 0..3: rect x0,y0,x1,y1
//   args 4..7: uv u0,v0,u1,v1
//   args 8..14: текстура + цвет + флаги (точная семантика не реверсена)
extern "C" void __fastcall Handler_SharedTexA(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	int32_t /*x0*/, int32_t /*y0*/, int32_t /*x1*/, int32_t /*y1*/,
	float /*u0*/, float /*v0*/, float /*u1*/, float /*v1*/,
	uint32_t /*a8*/, uint32_t /*maybe_textureID*/,
	int /*a10*/, int /*a11*/, int /*a12*/, int /*a13*/, int /*a14*/)
{
	// no-op — нужен правильный arity (15 args, ret 60) чтобы стек не порушить
}

// Slot 8: SharedTexB. Case 17 вторая ветка (новые пиксели в shared mem или
// в saved-stream). 17 args, ret 68. По реверсу case 17:
//   args 0..3: rect
//   args 4..7: uv
//   args 8: ?
//   args 9: textureID (?)
//   args 10: pixelDataSize
//   args 11: pixelBuf (malloc'нутый dispatcher'ом из shared mem)
//   args 12..13: width, height
//   args 14..15: ?
//   args 16: outOwns* (бит = "renderer забрал buffer себе, dispatcher не free'ит")
extern "C" void __fastcall Handler_SharedTexB(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	int32_t /*x0*/, int32_t /*y0*/, int32_t /*x1*/, int32_t /*y1*/,
	float /*u0*/, float /*v0*/, float /*u1*/, float /*v1*/,
	uint32_t /*a8*/, uint32_t /*maybe_textureID*/,
	uint32_t /*pixelDataSize*/, void* /*pixelBuf*/,
	int /*width*/, int /*height*/,
	int /*a14*/, int /*a15*/, char* outOwns)
{
	if (outOwns) *outOwns = 0;  // dispatcher сам free()'нёт pixelBuf
}

// Slot 9: post-frame setup. 0 args.
extern "C" void __fastcall Handler_PostFrame(GDIFakeRenderer* /*ecx*/, void* /*edx*/) {
}

// Slot 11: ScreenSize. Размер нашего внутреннего back-buffer'а
// (НЕ window client). Steam использует это как «render res» — пара с
// GetOutputBounds задаёт scale factor (`SetScaleFactors` в логе),
// который применяется к курсору и UI layout'у. Если возвращать client
// area, scale получается 1.0 — overlay будет в internal-coords,
// мышь в window-coords, маппинг ломается при resize'е окна.
extern "C" void __fastcall Handler_ScreenSize(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/,
	int32_t* width, int32_t* height)
{
	*width  = (g_back_w > 0) ? g_back_w : 1;
	*height = (g_back_h > 0) ? g_back_h : 1;
}

// Slot 12: DeleteTexture. 1 arg.
extern "C" void __fastcall Handler_DeleteTexture(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/, uint32_t textureID)
{
	Tex_Delete(textureID);
}

// Slot 13: ScreenshotComplete. 0 args.
extern "C" void __fastcall Handler_ScreenshotComplete(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/)
{
}

// Запрос на скриншот — main loop вычитывает после Present (back-buffer
// тогда содержит готовый кадр, а не свеже-cleared'нутый gray).
bool g_screenshot_requested = false;

// Slot 14: CaptureScreenshot. 2 args (a2=char, a3=int). Вызывается из
// M_present_update когда g_ScreenshotPending был выставлен paint_stream
// opcode 13 (= "F12 нажат"). Slot 14 dispatches'я ВПЕРЕДИ paint commands
// этого кадра, поэтому при немедленной capture'е back-buffer ещё пуст
// (cleared dark gray). Откладываем — main loop сделает реальный capture
// уже после Present (back-buffer = готовый кадр).
extern "C" void __fastcall Handler_CaptureScreenshot(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/, char /*to_overlay_ui*/, int /*id*/)
{
	g_screenshot_requested = true;
}

// Вызывается из public API после Present (back-buffer = готовый кадр).
void TakeScreenshotNow() {
	if (!g_back_pixels || g_back_w <= 0 || g_back_h <= 0) return;

	const int W = g_back_w, H = g_back_h;
	const size_t rgb_bytes = (size_t)W * H * 3;

	// 1. Локальный BMP — debug удобство. Tex_SaveToBMP пишет с
	// biHeight=-H (top-down). Если caller дал bottom-up buffer —
	// инвертируем знак чтобы BMP получился правильной ориентации.
	char filename[64];
	SYSTEMTIME st;
	GetLocalTime(&st);
	snprintf(filename, sizeof(filename),
	         "screenshot_%04d%02d%02d_%02d%02d%02d.bmp",
	         st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
	Tex_SaveToBMP(filename, g_back_pixels, W, g_back_bottom_up ? -H : H);
	Logger::info(std::format("  [screenshot] saved: {}\n", filename));

	// 2. Steam library upload — нужен RGB24 top-down. Если caller дал
	// bottom-up — читаем строки в обратном порядке при конвертации.
	auto* rgb = (uint8_t*)malloc(rgb_bytes);
	if (!rgb) return;

	const uint8_t* bgra = (const uint8_t*)g_back_pixels;
	for (int y = 0; y < H; ++y) {
		const int src_y = g_back_bottom_up ? (H - 1 - y) : y;
		const uint8_t* src_row = bgra + (size_t)src_y * W * 4;
		uint8_t*       dst_row = rgb  + (size_t)y     * W * 3;
		for (int x = 0; x < W; ++x) {
			dst_row[x*3 + 0] = src_row[x*4 + 2];  // R
			dst_row[x*3 + 1] = src_row[x*4 + 1];  // G
			dst_row[x*3 + 2] = src_row[x*4 + 0];  // B
		}
	}

	auto* ss = GetSteamScreenshots(GetSteamFns());
	if (ss) {
		ScreenshotHandle h = ss->WriteScreenshot(rgb, (uint32)rgb_bytes, W, H);
		Logger::info(std::format("  [screenshot] uploaded to Steam library, handle={}\n", h));
	} else {
		Logger::warning("  [screenshot] SteamScreenshots() unavailable\n");
	}

	free(rgb);
}

// Slot 20: GetHWND. Возврат HWND в eax (через return). M_present_update в
// конце frame'а вызывает vtable[19/20/21/24] чтобы собрать window state
// для overlay-positioning (sub_10083040). Без правильного HWND Steam
// падает на глобальную DLL'евую переменную = 0 → координаты курсора
// мапятся неправильно (overlay думает что cursor right-below реального).
extern "C" HWND __fastcall Handler_GetHWND(GDIFakeRenderer* /*ecx*/, void* /*edx*/) {
	return s_hwnd;
}

// Slot 26: GetOutputBounds. 4 outparam pointers (x, y, w, h).
// Возвращаем SCREEN-АБСОЛЮТНЫЕ координаты нашего client area + размер.
// Steam логирует это как "ValveGetOutputBounds(x, y, w, h)" и (предположение)
// использует (x, y) для cursor transform: screen_cursor − (x, y) = overlay_local.
// Если возвращать (0, 0) — Steam думает что наше окно на экране в (0, 0)
// → cursor mapping ломается когда окно где-то на экране, не в углу.
extern "C" void __fastcall Handler_GetOutputBounds(
	GDIFakeRenderer* /*dev*/, void* /*edx*/,
	int32_t* x, int32_t* y, int32_t* width, int32_t* height)
{
	POINT origin = {0, 0};
	ClientToScreen(s_hwnd, &origin);  // screen-абс coords client (0,0)
	RECT clientRect;
	GetClientRect(s_hwnd, &clientRect);
	*x = origin.x;
	*y = origin.y;
	*width = clientRect.right - clientRect.left;
	*height = clientRect.bottom - clientRect.top;
}

// Slot 27: GetClassName → const char*. 0 args. Возврат в eax.
extern "C" const char* __fastcall Handler_GetClassName(
	GDIFakeRenderer* /*ecx*/, void* /*edx*/)
{
	return "GDIFakeRenderer";
}

// Thunk'и для не-override'нутых vtable слотов. Раньше тянули nullsub'ы
// из DLL чтобы матчить layout реальных renderer'ов, но dispatcher не
// различает откуда функция — только ABI важен. Свои thunk'и не плывут
// при Steam update'ах. __stdcall callee-cleans стек на N×4 байт = ровно
// то что нужно __thiscall'у dispatcher'а (ecx=this игнорируем).
extern "C" void __stdcall Thunk_Ret0()    {}  // → ret
extern "C" void __stdcall Thunk_Ret4(int) {}  // → ret 4

// ---------------------------------------------------------------
// InitFakeRenderer: собираем vtable + инициализируем структуру.
// ---------------------------------------------------------------
void InitGDIFakeRenderer(GDIFakeRenderer* dev, const VtableLayout& layout, HWND hwnd) {
	s_hwnd = hwnd;
	void* thunk_ret0 = (void*)&Thunk_Ret0;
	void* thunk_ret4 = (void*)&Thunk_Ret4;

	// Заливаем все слоты thunk_ret0 — безопасный default для arity=0 слотов.
	// Слоты-с-аргументами override'им явно ниже.
	for (int i = 0; i < layout.total_slots; ++i) {
		g_vtable_storage[i] = thunk_ret0;
	}

	// Override slots:
	g_vtable_storage[layout.slot_dtor]                 = thunk_ret4;  // 1 arg
	g_vtable_storage[layout.slot_FrameStart]           = (void*)&Handler_FrameStart;
	g_vtable_storage[layout.slot_DrawTexturedRect]     = (void*)&Handler_DrawTexturedRect;
	g_vtable_storage[layout.slot_LoadTexture]          = (void*)&Handler_LoadTexture;
	g_vtable_storage[layout.slot_SetChromePaintSource] = (void*)&Handler_SetChromePaintSource;
	g_vtable_storage[layout.slot_SharedTexA]           = (void*)&Handler_SharedTexA;
	g_vtable_storage[layout.slot_SharedTexB]           = (void*)&Handler_SharedTexB;
	g_vtable_storage[layout.slot_PostFrame]          = (void*)&Handler_PostFrame;
	g_vtable_storage[layout.slot_ScreenSize]         = (void*)&Handler_ScreenSize;
	g_vtable_storage[layout.slot_DeleteTexture]      = (void*)&Handler_DeleteTexture;
	g_vtable_storage[layout.slot_ScreenshotComplete] = (void*)&Handler_ScreenshotComplete;
	g_vtable_storage[layout.slot_CaptureScreenshot]  = (void*)&Handler_CaptureScreenshot;
	g_vtable_storage[layout.slot_GetHWND]            = (void*)&Handler_GetHWND;
	g_vtable_storage[layout.slot_RetFour]            = thunk_ret4;  // 1 arg
	g_vtable_storage[layout.slot_GetOutputBounds]    = (void*)&Handler_GetOutputBounds;
	g_vtable_storage[layout.slot_GetClassName]       = (void*)&Handler_GetClassName;

	// Привязываем vtable к struct'е.
	dev->vtable = g_vtable_storage;

	// SharedTextureObject для слота shared_tex_obj_98.
	// unsafe — fixes nullptr crash at .text:100A084F; но потом dispatcher
	// падает в .text:100A06C0 (probably sub_100A35A0 breaks stack).
	dev->shared_tex_obj_98 = new SharedTextureObject;
}
