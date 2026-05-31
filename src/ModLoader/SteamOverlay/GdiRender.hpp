// GDI texture cache + software-blend на ВНЕШНЕМ back-buffer'е.
//
// Back-buffer не принадлежит этому модулю — caller (через public API
// SteamOverlay_RenderFrame) даёт указатель на свой BGRA8 pixel buffer.
// Tex_DrawRect блендит overlay прямо туда. Ориентация буфера — top-down
// (default) или bottom-up (см. g_back_bottom_up).
//
// Texture cache (LoadTexture результаты) — наш, держим как DIB sections
// в памяти процесса.

#pragma once

#include <cstdint>
#include <Windows.h>

// External back-buffer, передаётся caller'ом каждый кадр.
// Пиксели — BGRA8, ориентация определяется g_back_bottom_up.
extern uint32_t* g_back_pixels;
extern int       g_back_w;
extern int       g_back_h;

// true — caller передал bottom-up DIB (positive biHeight у CreateDIBSection),
// и мы должны инвертировать y при записи. false (default) — top-down.
extern bool      g_back_bottom_up;

// Главный цикл клирит back-buffer caller side. Steam не всегда шлёт
// DrawRect'ы каждый тик (FPS ~30Hz, мы можем 60Hz). Если в кадре ничего
// не нарисовали, caller может skip'нуть BitBlt — окно сохранит прошлый кадр.
extern bool g_drew_this_frame;

void Tex_LoadOrUpdate(uint32_t id, uint32_t ux, uint32_t uy,
                      uint32_t w, uint32_t h, const void* src);
void Tex_Delete(uint32_t id);

void Tex_DrawRect(uint32_t textureID,
                  int dx, int dy, int dw, int dh,
                  float u0, float v0, float u1, float v1,
                  uint32_t color);

// Сохранить произвольный BGRA top-down буфер как BMP. Используется
// screenshot path'ом для local-debug дампа кадра.
void Tex_SaveToBMP(const char* filename,
                   const uint32_t* pixels, int width, int height);
