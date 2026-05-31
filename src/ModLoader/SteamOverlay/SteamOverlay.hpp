// Public API библиотеки.
//
// Подцепляем Steam overlay (FPS counter, notifications, Shift+Tab UI,
// screenshots) к существующему Win32-окну и его back-buffer'у. Никаких
// хуков на чужие функции, никакого injection — чистый IPC контракт с
// gameoverlayui64.exe через GameOverlayRenderer.dll.
//
// Платформа: Win32 / x86-32. Сборка как DLL/SO для других архитектур
// потребует перенесения naked __thiscall thunk'ов.

#pragma once

#include <cstdint>
#include <Windows.h>

#ifdef __cplusplus
extern "C" {
#endif

// Инициализация. Делать ОДИН РАЗ после CreateWindow + ShowWindow.
//
//   hwnd:  ваше окно. Должно быть видимым (overlay использует его HWND для
//          cursor mapping и raw input). Raw input регистрируется на это
//          окно — caller НЕ должен сам RegisterRawInputDevices.
//   appid: опционально. Если передан — выставляем env vars (SteamAppId/
//          SteamGameId/SteamOverlayGameId) и зовём RestartAppIfNecessary,
//          чтобы запуск произошёл через Steam если он не был. Если 0
//          (по умолчанию) — пропускаем эти шаги, Steam определяет AppID
//          сам через steam_appid.txt, существующие env vars, или launcher
//          context.
//
// Возвращает false если: Steam не запущен, SteamAPI_Init упал, или
// GameOverlayRenderer.dll не загружен (Steam отключил overlay в настройках).
bool SteamOverlay_Init(HWND hwnd, uint32_t appid = 0);

// Per-frame: блендит overlay UI поверх ваших пикселей.
//
//   pixels:    BGRA8 DIB-style buffer с уже отрендеренной сценой игры.
//              Overlay рисуется ПОВЕРХ (alpha-blend).
//   width, height: размеры буфера = текущий client area HWND'а.
//   bottom_up: false (default) — top-down DIB (biHeight отрицательный,
//                                row 0 = верх кадра).
//              true            — bottom-up DIB (biHeight положительный,
//                                row 0 = низ кадра). Windows GDI CreateDIBSection
//                                с положительной высотой возвращает такой.
//
// До вызова: ваш back-buffer содержит сцену игры.
// После вызова: ваш back-buffer = сцена + overlay (если есть что показать).
//
// Caller остаётся ответственным за Present (BitBlt в окно или эквивалент).
//
// Заодно внутри: SteamAPI_RunCallbacks(), heartbeat в secondary stream,
// screenshot capture если F12 был нажат в прошлом кадре.
void SteamOverlay_RenderFrame(uint32_t* pixels, int width, int height,
                              bool bottom_up = false);

// Cleanup. SteamAPI_Shutdown + освобождение наших ресурсов.
void SteamOverlay_Shutdown();

#ifdef __cplusplus
}
#endif
