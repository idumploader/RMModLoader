#include "SteamLoader.hpp"

#include "Logger.hpp"
#include "../Steam/steam_api.h"  // ISteamFriends, ISteamScreenshots, version macros

#include <cstdio>
#include <format>

using rm_modloader::Logger;

bool LoadSteamApi(SteamFns& fns) {
	if (fns.module) return true;

	fns.module = LoadLibraryA("steam_api.dll");
	if (!fns.module) {
		Logger::warning(std::format("[steam_overlay] steam_api.dll not found (GetLastError={})\n",
		                            GetLastError()));
		return false;
	}

	// Required exports — нет → fail.
	bool ok = true;
	auto get_req = [&](const char* name) -> FARPROC {
		FARPROC p = GetProcAddress(fns.module, name);
		if (!p) {
			Logger::error(std::format("[steam_overlay] steam_api.dll missing export: {}\n", name));
			ok = false;
		}
		return p;
	};
	// Optional — нет → silently nullptr (зовущая сторона разберётся).
	auto get_opt = [&](const char* name) -> FARPROC {
		return GetProcAddress(fns.module, name);
	};

	fns.InitFlat                  = reinterpret_cast<SteamFns::PFN_InitFlat>             (get_opt("SteamAPI_InitFlat"));
	fns.InitLegacy                = reinterpret_cast<SteamFns::PFN_InitLegacy>           (get_opt("SteamAPI_Init"));
	fns.RestartAppIfNecessary     = reinterpret_cast<SteamFns::PFN_RestartAppIfNecessary>(get_req("SteamAPI_RestartAppIfNecessary"));
	fns.Shutdown                  = reinterpret_cast<SteamFns::PFN_Shutdown>             (get_req("SteamAPI_Shutdown"));
	fns.RunCallbacks              = reinterpret_cast<SteamFns::PFN_RunCallbacks>         (get_req("SteamAPI_RunCallbacks"));
	fns.GetHSteamUser             = reinterpret_cast<SteamFns::PFN_GetHSteamUser>        (get_req("SteamAPI_GetHSteamUser"));
	fns.FindOrCreateUserInterface = reinterpret_cast<SteamFns::PFN_FindOrCreate>         (get_req("SteamInternal_FindOrCreateUserInterface"));

	if (!fns.InitFlat && !fns.InitLegacy) {
		Logger::error("[steam_overlay] steam_api.dll has neither SteamAPI_InitFlat nor SteamAPI_Init export\n");
		ok = false;
	}

	if (!ok) {
		UnloadSteamApi(fns);
		return false;
	}
	return true;
}

bool CallSteamApiInit(const SteamFns& fns, char err_out[1024]) {
	if (fns.InitFlat) {
		return fns.InitFlat(err_out) == 0;
	}
	if (fns.InitLegacy) {
		if (err_out) err_out[0] = '\0';
		return fns.InitLegacy();
	}
	if (err_out) std::snprintf(err_out, 1024, "no Init export");
	return false;
}

void UnloadSteamApi(SteamFns& fns) {
	if (fns.module) FreeLibrary(fns.module);
	fns = {};
}

ISteamFriends* GetSteamFriends(const SteamFns& fns) {
	if (!fns.FindOrCreateUserInterface || !fns.GetHSteamUser) return nullptr;
	return static_cast<ISteamFriends*>(
		fns.FindOrCreateUserInterface(fns.GetHSteamUser(), STEAMFRIENDS_INTERFACE_VERSION));
}

ISteamScreenshots* GetSteamScreenshots(const SteamFns& fns) {
	if (!fns.FindOrCreateUserInterface || !fns.GetHSteamUser) return nullptr;
	return static_cast<ISteamScreenshots*>(
		fns.FindOrCreateUserInterface(fns.GetHSteamUser(), STEAMSCREENSHOTS_INTERFACE_VERSION));
}
