#include "SteamOverlay.hpp"

#include "../Steam/steam_api.h"  // ISteamFriends

#include "DllResolver.hpp"
#include "FakeRenderer.hpp"
#include "GdiRender.hpp"
#include "IpcStreams.hpp"
#include "Logger.hpp"
#include "SteamLoader.hpp"

#include <cstdint>
#include <cstring>
#include <format>

using rm_modloader::Logger;

namespace {
	GDIFakeRenderer  g_dev;
	ResolvedRenderer g_resolved;
	char             g_secondary_stream_buf[0x200];
	bool             g_initialized = false;
	SteamFns         g_steam;
}

// Используется FakeRenderer.cpp для screenshot upload.
const SteamFns& GetSteamFns() { return g_steam; }

bool SteamOverlay_Init(HWND hwnd, uint32_t appid) {
	if (g_initialized) return true;
	if (!hwnd) return false;

	// Если host уже сделал Logger::init — init вернёт -1 и наш вызов
	// будет no-op'ом, host'ovsky сетап сохранится. Иначе пишем в stdout.
	Logger::init(std::nullopt);

	if (appid != 0) {
		// AppId env-vars — некоторые компоненты Steam'а смотрят туда.
		char appid_str[16];
		snprintf(appid_str, sizeof(appid_str), "%u", appid);
		SetEnvironmentVariableA("SteamAppId",          appid_str);
		SetEnvironmentVariableA("SteamGameId",         appid_str);
		SetEnvironmentVariableA("SteamOverlayGameId",  appid_str);
	}

	if (!LoadSteamApi(g_steam)) {
		Logger::warning("[steam_overlay] steam_api.dll unavailable\n");
		return false;
	}

	if (appid != 0 && g_steam.RestartAppIfNecessary(appid)) {
		Logger::info("[steam_overlay] Restart through Steam, please\n");
		UnloadSteamApi(g_steam);
		return false;
	}
	char steam_err[1024] = {};
	if (!CallSteamApiInit(g_steam, steam_err)) {
		Logger::error(std::format("[steam_overlay] SteamAPI init failed: {}\n", steam_err));
		UnloadSteamApi(g_steam);
		return false;
	}
	if (auto* fr = GetSteamFriends(g_steam)) {
		Logger::info(std::format("[steam_overlay] Steam initialized: {}\n", fr->GetPersonaName()));
	}

	if (!ResolveRenderer(g_resolved)) {
		g_steam.Shutdown();
		UnloadSteamApi(g_steam);
		return false;
	}

	// Raw input на наше окно — без этого M_present_update force-disable'ит
	// overlay при попытке открыть (Failed getting currently registered
	// raw input devices).
	RAWINPUTDEVICE rid[2] = {};
	rid[0].usUsagePage = 0x01;  // Generic Desktop
	rid[0].usUsage     = 0x06;  // Keyboard
	rid[0].hwndTarget  = hwnd;
	rid[1].usUsagePage = 0x01;
	rid[1].usUsage     = 0x02;  // Mouse
	rid[1].hwndTarget  = hwnd;
	if (!RegisterRawInputDevices(rid, 2, sizeof(RAWINPUTDEVICE))) {
		Logger::warning(std::format("[steam_overlay] RegisterRawInputDevices failed: {}\n",
		                            GetLastError()));
	}

	// Fake renderer setup — vtable + struct fields.
	InitGDIFakeRenderer(&g_dev, kLayout_2026_05, hwnd);
	// flag_72=1 — заставляет dispatcher пропустить first-switch (frame-setup),
	// каждый opcode идёт сразу во второй switch.
	g_dev.flag_72 = 1;

	// Свой CSharedMemStream для secondary_stream'а. M_present_update
	// проверяет его GetLocalPending() каждый кадр; если 0 и
	// byte_10124504 && !byte_10124505 — force-disable. Мы пишем туда
	// 1 байт heartbeat'а каждый кадр.
	Call_M_MakeCSharedMemStream(g_secondary_stream_buf,
	                            "GameOverlayRender_OurSecondaryHeartbeat",
	                            /*capacity*/ 0x400, /*ttl*/ 100,
	                            /*a5*/ 0, /*a6*/ 0);
	g_dev.secondary_stream = g_secondary_stream_buf;

	Logger::info(std::format("[steam_overlay] ready. device={} secondary_stream={}\n",
	                         (void*)&g_dev, (void*)g_dev.secondary_stream));

	g_initialized = true;
	return true;
}

void SteamOverlay_RenderFrame(uint32_t* pixels, int width, int height, bool bottom_up) {
	if (!g_initialized || !pixels || width <= 0 || height <= 0) return;

	// Привязываем caller'овский back-buffer к нашим рендер-функциям.
	g_back_pixels = pixels;
	g_back_w      = width;
	g_back_h      = height;
	g_back_bottom_up = bottom_up;
	g_drew_this_frame = false;

	// Heartbeat в secondary stream чтобы M_present_update'овский watchdog
	// не триггерил force-disable. dispatcher прочитает 4 байта opcode'а
	// (наш 1 байт + 3 байта мусора), залогирует "Corrupt render stream"
	// в gameoverlayui (косметика), но force-disable не сработает.
	const uint8_t heartbeat = 0x04;
	Call_M_write_data(g_dev.secondary_stream, &heartbeat, 1);

	// Главный driver: dispatcher → читает paint stream → дёргает наши
	// vtable handler'ы → они рисуют в g_back_pixels.
	Call_M_present_update(&g_dev);

	// Screenshot capture отложен сюда из slot 14 — back-buffer теперь
	// содержит готовый кадр (с overlay сверху).
	if (g_screenshot_requested) {
		TakeScreenshotNow();
		g_screenshot_requested = false;
	}

	g_steam.RunCallbacks();
}

void SteamOverlay_Shutdown() {
	if (!g_initialized) return;
	g_steam.Shutdown();
	UnloadSteamApi(g_steam);
	g_initialized = false;
}
