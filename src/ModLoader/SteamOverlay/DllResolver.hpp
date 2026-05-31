// Resolve адресов в GameOverlayRenderer.dll (32-bit, in our process).
//
// Все RVA вычисляются runtime'ом сканом сигнатур (см. DllResolver.cpp,
// ResolveOffsetsViaSig). Якоря — это уникальные строки и idiom'ы в коде
// DLL которые переживают пересборку. Если Steam меняет лог-строки или
// меняет паттерн вызова M_ProcessPaintStream — сигнатуры протухнут,
// resolver вернёт false и оверлей не запустится (вместо silent crash'а).

#pragma once

#include <cstdint>
#include <Windows.h>

struct GDIFakeRenderer;      // fwd-decl: dispatcher работает с этим типом
struct CSharedMemStream;     // непрозрачный, передаём только указатель

struct RendererOffsets {
	uintptr_t M_ProcessPaintStream;
	uintptr_t M_present_update;
	uintptr_t M_MakeCSharedMemStream;
	uintptr_t M_write_data;
	uintptr_t g_IsOverlayEnabled;
	uintptr_t g_SharedPaintStream;
	uintptr_t g_SharedInputStream;
	uintptr_t g_SharedScreenshotStream;
};

extern RendererOffsets g_off;

struct ResolvedRenderer {
	HMODULE base = nullptr;

	// dispatcher — 32-bit __thiscall (ecx=this, args на стеке). Имитируем
	// через __fastcall с dummy edx — компилятор положит arg0 в ecx,
	// arg1 (=0) в edx, arg2 на стек; dispatcher прочитает ecx как this и
	// первый push со стека как paint_stream.
	using PFN_Dispatcher = void(__fastcall*)(
		GDIFakeRenderer* /*ecx=this*/, void* /*edx_dummy*/,
		CSharedMemStream* /*stack arg0*/);
	PFN_Dispatcher M_ProcessPaintStream = nullptr;

	// M_present_update — `void __thiscall(this)`. Зовётся из всех Present-хуков
	// (wglSwapBuffers, IDXGISwapChain::Present и т.д.). Внутри:
	//   1. M_GetRunningTime → пишет в [this+0x38]
	//   2. Регистрирует this в dword_1014928C (current renderer registry)
	//   3. Вызывает M_ProcessPaintStream(this, g_SharedPaintStream)
	//   4. 6-сек watchdog на secondary_stream → force-disable если не дышит
	//   5. timeBeginPeriod/Sleep frame-pacing
	using PFN_PresentUpdate = void(__fastcall*)(
		GDIFakeRenderer* /*ecx=this*/, void* /*edx_dummy*/);
	PFN_PresentUpdate M_present_update = nullptr;

	CSharedMemStream** pp_g_SharedPaintStream = nullptr;
	BYTE*              p_g_IsOverlayEnabled   = nullptr;
};

bool ResolveRenderer(ResolvedRenderer& r);

// Патч g_IsOverlayEnabled в 1. В обычной D3D-игре это ставится Present-хуком
// после первого успешного render-кадра. У GDI-host'а Present-хука нет —
// ставим вручную через VirtualProtect.
void PatchOverlayEnabled(BYTE* p);

// Naked thunk для вызова M_present_update(this). Зачем не звать через
// __fastcall(this, dummy_edx) напрямую: MSVC Debug RTCC #0 перепроверяет
// ESP после возврата и кричит false-positive из-за __fastcall vs __thiscall
// mismatch'а в типе указателя (хотя бинарно совместимо). Naked __cdecl-обёртка
// выглядит для RTCC прозрачно.
extern "C" uintptr_t g_addr_M_present_update;
extern "C" void Call_M_present_update(GDIFakeRenderer* /*this*/);

// CSharedMemStream API. M_MakeCSharedMemStream создаёт stream'у in-place
// в нашем buffer'е (this layout = ~0x140 байт). M_write_data пишет в её ring.
//
// Сигнатуры (наш реверс):
//   M_MakeCSharedMemStream(this, name, capacity, ttl, a5, a6)
//   M_write_data(this, data, size)
// Оба __thiscall.
extern "C" uintptr_t g_addr_M_MakeCSharedMemStream;
extern "C" uintptr_t g_addr_M_write_data;

// Naked thunks для обхода MSVC RTCC #0 (см. Call_M_present_update коммент).
extern "C" void  Call_M_MakeCSharedMemStream(void* stream_buf, const char* name,
                                             uint32_t capacity, int ttl,
                                             uint32_t a5, int a6);
extern "C" void  Call_M_write_data(void* stream_buf, const void* data, uint32_t size);
