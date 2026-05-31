#include "DllResolver.hpp"

#include "Logger.hpp"

#include <cstring>
#include <format>

using rm_modloader::Logger;

RendererOffsets g_off;

extern "C" uintptr_t g_addr_M_present_update = 0;
extern "C" uintptr_t g_addr_M_MakeCSharedMemStream = 0;
extern "C" uintptr_t g_addr_M_write_data = 0;

extern "C" void __declspec(naked) Call_M_present_update(GDIFakeRenderer* /*this*/) {
	__asm {
		mov  ecx, [esp + 4]                      // [esp+0]=ret, [esp+4]=arg0
		call dword ptr [g_addr_M_present_update] // M_present_update — ret 0 внутри
		ret                                      // __cdecl: caller cleans 1 arg
	}
}

// M_MakeCSharedMemStream(this, name, cap, ttl, a5, a6) — __thiscall, 5 stack args.
extern "C" void __declspec(naked) Call_M_MakeCSharedMemStream(
	void* /*stream_buf*/, const char* /*name*/, uint32_t /*capacity*/,
	int /*ttl*/, uint32_t /*a5*/, int /*a6*/)
{
	__asm {
		mov  ecx, [esp + 4]
		push [esp + 24]
		push [esp + 24]
		push [esp + 24]
		push [esp + 24]
		push [esp + 24]
		call dword ptr [g_addr_M_MakeCSharedMemStream]
		ret
	}
}

// M_write_data(this, data, size) — __thiscall, 2 stack args.
extern "C" void __declspec(naked) Call_M_write_data(
	void* /*stream_buf*/, const void* /*data*/, uint32_t /*size*/)
{
	__asm {
		mov  ecx, [esp + 4]
		push [esp + 12]
		push [esp + 12]
		call dword ptr [g_addr_M_write_data]
		ret
	}
}

// =====================================================================
// Sig-based resolver. Все RVA в DLL подсчитываются при ResolveRenderer
// сканом сигнатур, чтобы выдержать пересборку DLL без правок кода.
// =====================================================================

namespace {

struct Range { const uint8_t* start; const uint8_t* end; };

bool GetSection(HMODULE dll, const char* name, Range& out) {
	auto* base = reinterpret_cast<const uint8_t*>(dll);
	auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
	if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
	auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
	if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
	auto* sec = IMAGE_FIRST_SECTION(nt);
	for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
		if (std::strncmp(reinterpret_cast<const char*>(sec[i].Name), name, 8) == 0) {
			out.start = base + sec[i].VirtualAddress;
			out.end   = out.start + sec[i].Misc.VirtualSize;
			return true;
		}
	}
	return false;
}

// Parse "A0 ?? ?? ?? ?? C3" → byte+mask arrays. ?? = wildcard.
// Returns 0 on parse error, else length.
size_t ParseSig(const char* s, uint8_t* bytes, bool* mask, size_t cap) {
	auto hex = [](char c) -> int {
		if (c >= '0' && c <= '9') return c - '0';
		if (c >= 'a' && c <= 'f') return c - 'a' + 10;
		if (c >= 'A' && c <= 'F') return c - 'A' + 10;
		return -1;
	};
	size_t n = 0;
	while (*s) {
		while (*s == ' ') ++s;
		if (!*s) break;
		if (n >= cap) return 0;
		if (s[0] == '?' && s[1] == '?') {
			bytes[n] = 0; mask[n] = false; s += 2;
		} else {
			int hi = hex(s[0]), lo = hex(s[1]);
			if (hi < 0 || lo < 0) return 0;
			bytes[n] = static_cast<uint8_t>((hi << 4) | lo);
			mask[n]  = true;
			s += 2;
		}
		++n;
	}
	return n;
}

const uint8_t* Scan(const Range& r, const char* sig) {
	uint8_t bytes[128]; bool mask[128];
	size_t n = ParseSig(sig, bytes, mask, 128);
	if (n == 0 || static_cast<size_t>(r.end - r.start) < n) return nullptr;
	const uint8_t* last = r.end - n;
	for (const uint8_t* p = r.start; p <= last; ++p) {
		bool ok = true;
		for (size_t i = 0; i < n; ++i) {
			if (mask[i] && p[i] != bytes[i]) { ok = false; break; }
		}
		if (ok) return p;
	}
	return nullptr;
}

// Find ASCII string verbatim in range.
const uint8_t* FindString(const Range& r, const char* s) {
	size_t len = std::strlen(s);
	if (static_cast<size_t>(r.end - r.start) < len) return nullptr;
	const uint8_t* last = r.end - len;
	for (const uint8_t* p = r.start; p <= last; ++p) {
		if (std::memcmp(p, s, len) == 0) return p;
	}
	return nullptr;
}

// Search .text for `push imm32` where imm32 == addr.
const uint8_t* FindPushImm32(const Range& text, uint32_t imm) {
	uint8_t sig[5] = {
		0x68,
		static_cast<uint8_t>(imm),
		static_cast<uint8_t>(imm >> 8),
		static_cast<uint8_t>(imm >> 16),
		static_cast<uint8_t>(imm >> 24),
	};
	if (static_cast<size_t>(text.end - text.start) < 5) return nullptr;
	const uint8_t* last = text.end - 5;
	for (const uint8_t* p = text.start; p <= last; ++p) {
		if (std::memcmp(p, sig, 5) == 0) return p;
	}
	return nullptr;
}

uint32_t ReadU32(const uint8_t* p) {
	return static_cast<uint32_t>(p[0])
	     | (static_cast<uint32_t>(p[1]) << 8)
	     | (static_cast<uint32_t>(p[2]) << 16)
	     | (static_cast<uint32_t>(p[3]) << 24);
}

// `E8 disp32` → absolute target of the call.
const uint8_t* ResolveCall(const uint8_t* e8_instr) {
	int32_t disp = static_cast<int32_t>(ReadU32(e8_instr + 1));
	return e8_instr + 5 + disp;
}

// Walk backward looking for `55 8B EC` prolog. Каждый renderer-thunk
// в DLL начинается ровно с этих 3 байт.
const uint8_t* WalkBackToProlog(const uint8_t* p, size_t max_back = 0x4000) {
	for (size_t i = 0; i <= max_back; ++i) {
		const uint8_t* q = p - i;
		if (q[0] == 0x55 && q[1] == 0x8B && q[2] == 0xEC) {
			// Validate preceding byte — should be padding (CC), ret (C3),
			// nop (90), или int (CC). Если что-то другое — мы внутри функции,
			// продолжаем искать.
			uint8_t prev = q[-1];
			if (prev == 0xCC || prev == 0xC3 || prev == 0x90) {
				return q;
			}
		}
	}
	return nullptr;
}

// Convert absolute address to RVA (offset from DLL base).
uintptr_t ToRVA(const uint8_t* base, const uint8_t* abs) {
	return static_cast<uintptr_t>(abs - base);
}

bool ResolveOffsetsViaSig(HMODULE dll, RendererOffsets& off) {
	auto* base = reinterpret_cast<const uint8_t*>(dll);
	Range text, rdata;
	if (!GetSection(dll, ".text",  text) || !GetSection(dll, ".rdata", rdata)) {
		Logger::error("[sig] failed to find .text/.rdata sections\n");
		return false;
	}

	// --- g_IsOverlayEnabled via IsOverlayEnabled export.
	// Export is `mov al, byte ptr [imm32]; ret` = `A0 ?? ?? ?? ?? C3`.
	auto* iox = reinterpret_cast<const uint8_t*>(
		GetProcAddress(dll, "IsOverlayEnabled"));
	if (!iox || iox[0] != 0xA0) {
		Logger::error("[sig] IsOverlayEnabled export not found / not the expected shape\n");
		return false;
	}
	uint32_t overlay_byte = ReadU32(iox + 1);
	off.g_IsOverlayEnabled = overlay_byte - reinterpret_cast<uintptr_t>(base);

	// --- M_present_update via "Forcing internal overlay disable..." string.
	const char* kForcingStr = "Forcing internal overlay disable and requesting ui disable\n";
	auto* forcing = FindString(rdata, kForcingStr);
	if (!forcing) { Logger::error("[sig] 'Forcing internal...' string not found\n"); return false; }
	auto* push_forcing = FindPushImm32(text, static_cast<uint32_t>(reinterpret_cast<uintptr_t>(forcing)));
	if (!push_forcing) { Logger::error("[sig] push <Forcing> not found in .text\n"); return false; }
	auto* M_present_update = WalkBackToProlog(push_forcing);
	if (!M_present_update) { Logger::error("[sig] M_present_update prolog walkback failed\n"); return false; }
	off.M_present_update = ToRVA(base, M_present_update);

	// --- g_SharedPaintStream + M_ProcessPaintStream via паттерн в M_present_update:
	//   A1 [paint_global]   mov eax, [g_SharedPaintStream]
	//   85 C0               test eax, eax
	//   74 ??               jz   short ...
	//   50                  push eax
	//   ?? ??               mov  ecx, <this>  (regalloc выбор: edi/ebx/esi — wildcard)
	//   E8 [rel32]          call M_ProcessPaintStream
	//   84 C0               test al, al   (call вернул bool)
	//   74 ??               jz
	// Trailing `test al, al; jz` anchor'ит sig — compiler ВСЕГДА так проверяет
	// bool-результат, даже если regalloc для this изменился.
	const uint8_t* paint_anchor = Scan(text,
		"A1 ?? ?? ?? ?? 85 C0 74 ?? 50 ?? ?? E8 ?? ?? ?? ?? 84 C0 74");
	if (!paint_anchor) { Logger::error("[sig] paint anchor not found\n"); return false; }
	uint32_t paint_global_abs = ReadU32(paint_anchor + 1);
	off.g_SharedPaintStream = paint_global_abs - reinterpret_cast<uintptr_t>(base);
	auto* M_ProcessPaintStream = ResolveCall(paint_anchor + 12);
	off.M_ProcessPaintStream = ToRVA(base, M_ProcessPaintStream);

	// --- g_SharedInputStream via "Clearing input stream" environment:
	//   8B 0D [input_global]   mov ecx, [g_SharedInputStream]
	//   8B 01                  mov eax, [ecx]            (vtable)
	//   FF 50 08               call dword ptr [eax+8]    (GetAvailable)
	//   3D 00 01 00 00         cmp eax, 0x100
	const uint8_t* input_anchor = Scan(text,
		"8B 0D ?? ?? ?? ?? 8B 01 FF 50 08 3D 00 01 00 00");
	if (!input_anchor) { Logger::error("[sig] input anchor not found\n"); return false; }
	uint32_t input_global_abs = ReadU32(input_anchor + 2);
	off.g_SharedInputStream = input_global_abs - reinterpret_cast<uintptr_t>(base);

	// --- g_SharedScreenshotStream via "PaintCmdStream" string и idiom
	//   68 <PaintCmdStream> 6A FF A3 <screenshot_global>
	// (после Make screenshot пушится имя СЛЕДУЮЩЕГО stream'а перед store'ом).
	auto* paintcmd_str = FindString(rdata, "GameOverlayRender_PaintCmdStream_%d");
	if (!paintcmd_str) { Logger::error("[sig] PaintCmdStream string not found\n"); return false; }
	uintptr_t ps = reinterpret_cast<uintptr_t>(paintcmd_str);
	std::string ss_sig = std::format(
		"68 {:02X} {:02X} {:02X} {:02X} 6A FF A3 ?? ?? ?? ??",
		ps & 0xFF, (ps >> 8) & 0xFF, (ps >> 16) & 0xFF, (ps >> 24) & 0xFF);
	auto* ss_anchor = Scan(text, ss_sig.c_str());
	if (!ss_anchor) { Logger::error("[sig] screenshot anchor not found\n"); return false; }
	uint32_t screenshot_global_abs = ReadU32(ss_anchor + 8);
	off.g_SharedScreenshotStream = screenshot_global_abs - reinterpret_cast<uintptr_t>(base);

	// --- M_MakeCSharedMemStream via "GameOverlayRender_PIDStream" + forward `E8`.
	auto* pid_str = FindString(rdata, "GameOverlayRender_PIDStream");
	if (!pid_str) { Logger::error("[sig] PIDStream string not found\n"); return false; }
	auto* push_pid = FindPushImm32(text, static_cast<uint32_t>(reinterpret_cast<uintptr_t>(pid_str)));
	if (!push_pid) { Logger::error("[sig] push <PIDStream> not found\n"); return false; }
	const uint8_t* call_make = nullptr;
	for (size_t i = 5; i < 0x60; ++i) {
		if (push_pid[i] == 0xE8) { call_make = push_pid + i; break; }
	}
	if (!call_make) { Logger::error("[sig] forward E8 after PIDStream push not found\n"); return false; }
	off.M_MakeCSharedMemStream = ToRVA(base, ResolveCall(call_make));

	// --- M_write_data via уникальный prefix лог-строки.
	// FindString возвращает позицию подстроки; чтобы получить адрес как его
	// видит push в коде, нужно искать строку C-целиком (включая начало).
	// Есть две похожие; M_write_data использует ту что про "Need to write through".
	auto* lockstr = FindString(rdata,
		"CSharedMemStream has memory already locked for put. Need");
	if (!lockstr) { Logger::error("[sig] 'CSharedMemStream...Need' string not found\n"); return false; }
	auto* push_lock = FindPushImm32(text, static_cast<uint32_t>(reinterpret_cast<uintptr_t>(lockstr)));
	if (!push_lock) { Logger::error("[sig] push <lockstr> not found\n"); return false; }
	auto* M_write_data = WalkBackToProlog(push_lock);
	if (!M_write_data) { Logger::error("[sig] M_write_data prolog walkback failed\n"); return false; }
	off.M_write_data = ToRVA(base, M_write_data);

	return true;
}

}  // namespace

bool ResolveRenderer(ResolvedRenderer& r) {
	r.base = GetModuleHandleA("GameOverlayRenderer.dll");
	if (!r.base) {
		Logger::error("GameOverlayRenderer.dll not loaded — was SteamAPI_Init successful?\n");
		return false;
	}
	if (!ResolveOffsetsViaSig(r.base, g_off)) {
		Logger::error("[steam_overlay] sig-based offset resolution failed — "
		              "Steam updated DLL beyond known anchors?\n");
		return false;
	}

	BYTE* base = reinterpret_cast<BYTE*>(r.base);
	r.M_ProcessPaintStream = reinterpret_cast<ResolvedRenderer::PFN_Dispatcher>(base + g_off.M_ProcessPaintStream);
	r.M_present_update     = reinterpret_cast<ResolvedRenderer::PFN_PresentUpdate>(base + g_off.M_present_update);
	g_addr_M_present_update       = reinterpret_cast<uintptr_t>(base + g_off.M_present_update);
	g_addr_M_MakeCSharedMemStream = reinterpret_cast<uintptr_t>(base + g_off.M_MakeCSharedMemStream);
	g_addr_M_write_data           = reinterpret_cast<uintptr_t>(base + g_off.M_write_data);
	r.pp_g_SharedPaintStream = reinterpret_cast<CSharedMemStream**>(base + g_off.g_SharedPaintStream);
	r.p_g_IsOverlayEnabled   = base + g_off.g_IsOverlayEnabled;

	Logger::info(std::format(
		"GameOverlayRenderer.dll @ {}\n"
		"  M_ProcessPaintStream    RVA 0x{:X}\n"
		"  M_present_update        RVA 0x{:X}\n"
		"  M_MakeCSharedMemStream  RVA 0x{:X}\n"
		"  M_write_data            RVA 0x{:X}\n"
		"  g_IsOverlayEnabled      RVA 0x{:X}  = {}\n"
		"  g_SharedPaintStream     RVA 0x{:X}  *= {}\n"
		"  g_SharedInputStream     RVA 0x{:X}\n"
		"  g_SharedScreenshotStream RVA 0x{:X}\n",
		(void*)r.base,
		g_off.M_ProcessPaintStream, g_off.M_present_update,
		g_off.M_MakeCSharedMemStream, g_off.M_write_data,
		g_off.g_IsOverlayEnabled, (int)*r.p_g_IsOverlayEnabled,
		g_off.g_SharedPaintStream, (void*)*r.pp_g_SharedPaintStream,
		g_off.g_SharedInputStream, g_off.g_SharedScreenshotStream));
	return true;
}

void PatchOverlayEnabled(BYTE* p) {
	DWORD old = 0;
	if (VirtualProtect(p, 1, PAGE_READWRITE, &old)) {
		BYTE before = *p;
		*p = 1;
		VirtualProtect(p, 1, old, &old);
		Logger::info(std::format("Patched g_IsOverlayEnabled: {} -> 1\n", (int)before));
	}
}
