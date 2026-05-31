// GDIGDIFakeRenderer — fake device_context (= "render device" в терминах
// dispatcher'а GameOverlayRenderer.dll).
//
// АРХИТЕКТУРА:
//   - POD-struct без virtual'ов. На +0x00 лежит указатель на наш массив
//     `g_vtable_storage[]` (runtime-собранный), а дальше идут поля по
//     фиксированным offset'ам, которые dispatcher читает напрямую.
//   - Handler'ы — обычные `__fastcall(this, dummy_edx, ...args)` функции.
//     Это бинарно совместимо с __thiscall (ecx=this, args на стеке, callee
//     cleans), но позволяет писать их как free functions а не member'ы.
//   - Неиспользуемые слоты заполняются DLL'евыми thunk'ами (nullsub_1=ret 0,
//     nullsub_2=ret 4) — точно так же как реальные concrete renderer'ы
//     делают для не-overridden слотов.
//   - Layout слотов хранится в VtableLayout — при обновлении Steam'а
//     достаточно поменять числа в kLayout_<version>, перекомпиляция class'а
//     не нужна.
//
// Почему это лучше чем C++ class с virtual'ами: в C++ количество и порядок
// слотов зашиты компилятором в момент компиляции, и при изменении vtable
// в DLL приходилось вручную сдвигать `virtual void vN()` объявления. С
// manual vtable — просто меняем индексы в VtableLayout.

#pragma once

#include <cstdint>
#include <Windows.h>

// ---------------------------------------------------------------
// VtableLayout — структура для версионного маппинга. По одному инстансу
// на каждую версию gameoverlayrenderer.dll где layout изменился.
// ---------------------------------------------------------------
struct VtableLayout {
	int total_slots;             // 28 в build 2026-05
	int slot_dtor;               // 0  (arity 1: delete flag)
	int slot_FrameStart;         // 1  (arity 0)
	int slot_DrawTexturedRect;   // 3  (arity 13)
	int slot_LoadTexture;        // 4  (arity 11)
	// Slot 5 (arity 2) — Steam зовёт его из sub_100A35E0 (Chrome paint buffer
	// setup). Если оставить дефолтным nullsub_1 (ret 0), 8 байт со стека не
	// чистятся → корраптится сохранённый esi → AV при следующем чтении [esi].
	int slot_SetChromePaintSource; // 5 (arity 2)
	int slot_SharedTexA;         // 6  (arity 15 — case 17 первая ветка)
	int slot_SharedTexB;         // 8  (arity 17 — case 17 вторая ветка)
	int slot_PostFrame;          // 9  (arity 0)
	int slot_ScreenSize;         // 11 (arity 2 outparams)
	int slot_DeleteTexture;      // 12 (arity 1)
	int slot_ScreenshotComplete; // 13 (arity 0)
	int slot_CaptureScreenshot;  // 14 (arity 2, takes screen capture)
	int slot_GetHWND;            // 20 (arity 0, returns HWND of host window)
	int slot_RetFour;            // 23 — слот для ret-4 thunk'а
	int slot_GetOutputBounds;    // 26 (arity 4 outparams)
	int slot_GetClassName;       // 27 (arity 0, returns const char*)
};

// Текущая loaded версия. При update Steam'а — добавить kLayout_<new_date>
// и переключить или сделать version detection (например по размеру DLL).
extern const VtableLayout kLayout_2026_05;

// ---------------------------------------------------------------
// SharedTextureObject — opaque struct, dispatcher лезет внутрь по
// текстурным operation'ам. Минимальный self-referencing layout, чтобы
// проходить null-checks в dispatcher case 17.
// ---------------------------------------------------------------
struct SharedTextureObject {
	SharedTextureObject* texture0 = this; // +0x0
	SharedTextureObject* texture4 = this; // +0x4
	SharedTextureObject* texture8 = this; // +0x8
	int16_t unknownC = 257;               // +0xC
	int8_t pad[0x28 - 0x10]{};
};

// ---------------------------------------------------------------
// GDIFakeRenderer — POD struct. Field offsets read directly by dispatcher:
//   [+0x00]  vtable ptr (наш runtime-собранный массив)
//   [+0x08]  frame_lo  (case 0 BeginFrame)
//   [+0x0C]  frame_hi
//   [+0x38]  perfomance_counter (Steam сам пишет в начале M_present_update)
//   [+0x6C]  secondary_stream
//   [+0x72]  flag_72   (set=1 в frame-setup; если оставить 0 dispatcher
//                       идёт через first-switch с frame-setup'ом)
//   [+0x73]  flag_73   (enableClearOnEveryFrame, case 10)
//   [+0x90]  shared_tex_obj_90 (case 17)
//   [+0x98]  shared_tex_obj_98 (case 17)
//   [+0xA4]  ?float (velocity?)
//   [+0xA8]  frametime
// ---------------------------------------------------------------
#pragma pack(push, 4)
struct GDIFakeRenderer {
	void**   vtable = nullptr;            // +0x00 — set by InitGDIFakeRenderer
	uint32_t pad_04 = 0;
	uint32_t frame_lo = 0;                // +0x08
	uint32_t frame_hi = 0;                // +0x0C
	uint8_t  pad_10[0x38 - 0x10]{};
	DWORD    perfomance_counter = 0;      // +0x38
	uint8_t  pad_3C[0x6C - 0x3C]{};
	void*    secondary_stream = nullptr;  // +0x6C
	uint8_t  pad_70[0x72 - 0x70]{};
	uint8_t  flag_72 = 0;                 // +0x72
	uint8_t  flag_73 = 0;                 // +0x73
	uint8_t  pad_74[0x90 - 0x74]{};
	void*    shared_tex_obj_90 = (void*)0x10000; // +0x90 (sentinel, не nullptr)
	uint8_t  pad_94[0x98 - 0x94]{};
	void*    shared_tex_obj_98 = nullptr; // +0x98 — set by InitGDIFakeRenderer
	uint8_t  pad_9C[0xAC - 0x9C]{};
	float    frametime = 0.f;             // +0xAC
	uint8_t  pad_B0[0x200 - 0xB0]{};
};
#pragma pack(pop)

static_assert(offsetof(GDIFakeRenderer, frame_lo) == 0x08, "");
static_assert(offsetof(GDIFakeRenderer, perfomance_counter) == 0x38, "");
static_assert(offsetof(GDIFakeRenderer, secondary_stream) == 0x6C, "");
static_assert(offsetof(GDIFakeRenderer, flag_72) == 0x72, "");
static_assert(offsetof(GDIFakeRenderer, flag_73) == 0x73, "");
static_assert(offsetof(GDIFakeRenderer, frametime) == 0xAC, "");

// Инициализация: построить vtable storage и привязать его к dev->vtable.
// hwnd запоминается в static-переменной и читается в Handler_GetHWND /
// Handler_GetOutputBounds / Handler_ScreenSize.
void InitGDIFakeRenderer(GDIFakeRenderer* dev, const VtableLayout& layout, HWND hwnd);

// Screenshot capture (slot 14). Setting deferred until after Present so the
// back-buffer actually contains the rendered frame, not the gray clear.
extern bool g_screenshot_requested;
void TakeScreenshotNow();
