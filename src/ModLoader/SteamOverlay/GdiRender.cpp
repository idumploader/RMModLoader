#include "GdiRender.hpp"

#include <cstdio>
#include <cstring>
#include <unordered_map>

struct GDITexture {
	int     width = 0;
	int     height = 0;
	HBITMAP hbm = nullptr;
	void*   dib_pixels = nullptr;  // top-down DIB, BGRA8 (32-bit BI_RGB)
};

static std::unordered_map<uint32_t, GDITexture> g_textures;

// External back-buffer — caller's pixels. Updated each SteamOverlay_RenderFrame.
uint32_t* g_back_pixels = nullptr;
int       g_back_w      = 0;
int       g_back_h      = 0;
bool      g_back_bottom_up = false;
bool      g_drew_this_frame = false;

void Tex_LoadOrUpdate(uint32_t id, uint32_t ux, uint32_t uy,
                      uint32_t w, uint32_t h, const void* src)
{
	auto& tex = g_textures[id];

	const int needed_w = (int)(ux + w);
	const int needed_h = (int)(uy + h);

	if (!tex.hbm || tex.width < needed_w || tex.height < needed_h) {
		// Allocate / расширить — Steam не передаёт total atlas size явно,
		// мы автоматически растим DIB до нужного.
		const int new_w = (tex.width  > needed_w) ? tex.width  : needed_w;
		const int new_h = (tex.height > needed_h) ? tex.height : needed_h;

		BITMAPINFO bmi{};
		bmi.bmiHeader.biSize        = sizeof(bmi.bmiHeader);
		bmi.bmiHeader.biWidth       = new_w;
		bmi.bmiHeader.biHeight      = -new_h;       // отрицательная = top-down DIB
		bmi.bmiHeader.biPlanes      = 1;
		bmi.bmiHeader.biBitCount    = 32;
		bmi.bmiHeader.biCompression = BI_RGB;

		void*   new_pixels = nullptr;
		// CreateDIBSection с NULL DC — допустимо для BI_RGB, DC не нужен
		// потому что мы не блитим из этих DIB'ов в screen DC.
		HBITMAP new_hbm = CreateDIBSection(nullptr, &bmi, DIB_RGB_COLORS,
		                                   &new_pixels, nullptr, 0);
		if (!new_hbm) return;

		// Копируем старые пиксели в новый (top-left aligned), если был.
		if (tex.hbm && tex.dib_pixels) {
			for (int row = 0; row < tex.height; ++row) {
				memcpy((uint8_t*)new_pixels + (size_t)row * new_w * 4,
				       (uint8_t*)tex.dib_pixels + (size_t)row * tex.width * 4,
				       (size_t)tex.width * 4);
			}
			DeleteObject(tex.hbm);
		}
		tex.hbm        = new_hbm;
		tex.dib_pixels = new_pixels;
		tex.width      = new_w;
		tex.height     = new_h;
	}

	// Скопировать sub-rect (w×h) из src в DIB по offset (ux, uy).
	for (uint32_t row = 0; row < h; ++row) {
		memcpy((uint8_t*)tex.dib_pixels + ((size_t)(uy + row) * tex.width + ux) * 4,
		       (const uint8_t*)src + (size_t)row * w * 4,
		       (size_t)w * 4);
	}
}

void Tex_Delete(uint32_t id) {
	auto it = g_textures.find(id);
	if (it == g_textures.end()) return;
	if (it->second.hbm) DeleteObject(it->second.hbm);
	g_textures.erase(it);
}

// `height` — positive для top-down DIB (biHeight в BMP станет отрицательным),
// negative для bottom-up (biHeight станет положительным). Это match'ит
// Windows-style convention где знак biHeight определяет порядок строк.
void Tex_SaveToBMP(const char* filename,
                   const uint32_t* pixels, int width, int height)
{
	if (!pixels || width <= 0 || height == 0) return;
	const int abs_h = (height > 0) ? height : -height;

	BITMAPFILEHEADER bfh{};
	bfh.bfType    = 0x4D42; // 'BM'
	bfh.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
	bfh.bfSize    = bfh.bfOffBits + (DWORD)width * abs_h * 4;

	BITMAPINFOHEADER bih{};
	bih.biSize        = sizeof(bih);
	bih.biWidth       = width;
	bih.biHeight      = -height;       // sign-flip per Windows DIB convention
	bih.biPlanes      = 1;
	bih.biBitCount    = 32;
	bih.biCompression = BI_RGB;
	bih.biSizeImage   = (DWORD)width * abs_h * 4;

	FILE* f = fopen(filename, "wb");
	if (!f) return;
	fwrite(&bfh, sizeof(bfh), 1, f);
	fwrite(&bih, sizeof(bih), 1, f);
	fwrite(pixels, bih.biSizeImage, 1, f);
	fclose(f);
}

void Tex_DrawRect(uint32_t textureID,
                  int dx, int dy, int dw, int dh,
                  float u0, float v0, float u1, float v1,
                  uint32_t color)
{
	if (!g_back_pixels || dw <= 0 || dh <= 0) return;

	const int c_a = (color >> 24) & 0xFF;
	const int c_r = (color >> 16) & 0xFF;
	const int c_g = (color >>  8) & 0xFF;
	const int c_b = (color >>  0) & 0xFF;
	if (c_a == 0) return; // полностью прозрачный fill

	auto it = g_textures.find(textureID);
	const GDITexture* tex = (it == g_textures.end()) ? nullptr : &it->second;
	const uint32_t* tpx = (tex && tex->dib_pixels) ? (const uint32_t*)tex->dib_pixels : nullptr;
	const int       tw  = tex ? tex->width  : 0;
	const int       th  = tex ? tex->height : 0;

	// Clip to back buffer
	const int x0 = (dx > 0) ? dx : 0;
	const int y0 = (dy > 0) ? dy : 0;
	const int x1 = ((dx + dw) < g_back_w) ? (dx + dw) : g_back_w;
	const int y1 = ((dy + dh) < g_back_h) ? (dy + dh) : g_back_h;
	if (x0 >= x1 || y0 >= y1) return;

	g_drew_this_frame = true;

	const float u_per_dx = (u1 - u0) / (float)dw;
	const float v_per_dy = (v1 - v0) / (float)dh;

	for (int py = y0; py < y1; ++py) {
		const float v  = v0 + (py - dy + 0.5f) * v_per_dy;
		int   sy = (int)(v * th);
		if (tw && th) {
			if (sy < 0)        sy = 0;
			else if (sy >= th) sy = th - 1;
		}

		const int dst_y = g_back_bottom_up ? (g_back_h - 1 - py) : py;
		uint32_t* dst_row = g_back_pixels + (size_t)dst_y * g_back_w;

		for (int px = x0; px < x1; ++px) {
			// Sample texture (white if no texture).
			int t_b = 255, t_g = 255, t_r = 255, t_a = 255;
			if (tpx && tw && th) {
				const float u = u0 + (px - dx + 0.5f) * u_per_dx;
				int sx = (int)(u * tw);
				if (sx < 0)       sx = 0;
				else if (sx >= tw) sx = tw - 1;
				const uint32_t tp = tpx[(size_t)sy * tw + sx];
				t_b = (tp >>  0) & 0xFF;
				t_g = (tp >>  8) & 0xFF;
				t_r = (tp >> 16) & 0xFF;
				t_a = (tp >> 24) & 0xFF;
			}

			// Modulate by color (per-channel multiply).
			const int m_a = (t_a * c_a + 127) / 255;
			if (m_a == 0) continue;
			const int m_r = (t_r * c_r + 127) / 255;
			const int m_g = (t_g * c_g + 127) / 255;
			const int m_b = (t_b * c_b + 127) / 255;

			// Straight-alpha blend onto dst.
			const uint32_t dp = dst_row[px];
			const int d_b = (dp >>  0) & 0xFF;
			const int d_g = (dp >>  8) & 0xFF;
			const int d_r = (dp >> 16) & 0xFF;

			const int inv_a = 255 - m_a;
			const int o_b = (m_b * m_a + d_b * inv_a + 127) / 255;
			const int o_g = (m_g * m_a + d_g * inv_a + 127) / 255;
			const int o_r = (m_r * m_a + d_r * inv_a + 127) / 255;

			dst_row[px] = 0xFF000000u | ((uint32_t)o_r << 16) | ((uint32_t)o_g << 8) | (uint32_t)o_b;
		}
	}
}
