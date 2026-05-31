// Динамическая загрузка steam_api.dll. Хост-приложение, в которое
// встроена эта библиотека, может работать без Steam — `LoadSteamApi`
// просто вернёт false, и SteamOverlay_Init выйдет без падения.
//
// Используется ровно несколько exported функций steam_api.dll:
//   - SteamAPI_InitFlat        (новые SDK ≥ 1.58, с error-message)
//   - SteamAPI_Init            (legacy export, bool, no err msg — для старых DLL)
//   - SteamAPI_RestartAppIfNecessary
//   - SteamAPI_Shutdown
//   - SteamAPI_RunCallbacks
//   - SteamAPI_GetHSteamUser
//   - SteamInternal_FindOrCreateUserInterface
//
// Inline-accessor'ы из Steam header'ов (SteamFriends(), SteamScreenshots())
// не вызываем — они тянут dllimport'ы на S_API функции и привязывают
// нас к steam_api.lib. Вместо них — обёртки в этом файле.
//
// InitFlat и InitLegacy резолвятся обе попыточно; берётся та что DLL
// предоставляет. SteamOverlay_Init вызывает CallSteamApiInit, который
// прячет этот выбор за единым API.

#pragma once

#include <cstdint>
#include <Windows.h>

class ISteamFriends;
class ISteamScreenshots;

struct SteamFns {
	HMODULE module = nullptr;

	using PFN_InitFlat              = int   (__cdecl*)(char* err_out_1024);
	using PFN_InitLegacy            = bool  (__cdecl*)();
	using PFN_RestartAppIfNecessary = bool  (__cdecl*)(uint32_t);
	using PFN_Shutdown              = void  (__cdecl*)();
	using PFN_RunCallbacks          = void  (__cdecl*)();
	using PFN_GetHSteamUser         = int   (__cdecl*)();
	using PFN_FindOrCreate          = void* (__cdecl*)(int /*hSteamUser*/, const char* /*version*/);

	PFN_InitFlat              InitFlat              = nullptr;  // optional, modern SDK
	PFN_InitLegacy            InitLegacy            = nullptr;  // optional, old SDK
	PFN_RestartAppIfNecessary RestartAppIfNecessary = nullptr;
	PFN_Shutdown              Shutdown              = nullptr;
	PFN_RunCallbacks          RunCallbacks          = nullptr;
	PFN_GetHSteamUser         GetHSteamUser         = nullptr;
	PFN_FindOrCreate          FindOrCreateUserInterface = nullptr;
};

// Загружает steam_api.dll и резолвит нужные exports. Возвращает true
// если всё доступно. Если DLL отсутствует или какая-то функция не
// нашлась — возвращает false (например потому что host-app собран
// без Steam).
bool LoadSteamApi(SteamFns& fns);
void UnloadSteamApi(SteamFns& fns);

// Зовёт SteamAPI_InitFlat (новые SDK) или SteamAPI_Init (старые) —
// смотря что DLL предоставила. Возвращает true при успехе. err_out
// заполняется только если InitFlat доступен и вернул ошибку.
bool CallSteamApiInit(const SteamFns& fns, char err_out[1024]);

// Аналоги SteamFriends() / SteamScreenshots() через наш loader.
ISteamFriends*     GetSteamFriends(const SteamFns& fns);
ISteamScreenshots* GetSteamScreenshots(const SteamFns& fns);
