#include "../src/ModLoader/SteamOverlay/GdiRender.cpp"
#include <random>
#include <iostream>
#include <chrono>
#include <vector>
#include <stdexcept>
namespace rm_modloader::renderer {
int test_threads=1;
std::unique_ptr<RowPool> test_pool;
int raster_thread_count() { return test_threads; }
bool run_shared_raster_bands(void (*f)(void*,int) noexcept,void* p) {
    if (!test_pool) return false;
    test_pool->run(f,p);return true;
}
}
static void require(bool b) { if (!b) throw std::runtime_error("overlay raster mismatch"); }
void reference_draw(uint32_t textureID,
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

int main() {
    using namespace rm_modloader::renderer;
    std::mt19937 rng(19201080);
    std::vector<uint32_t> texture(257*129);
    for (auto& v:texture) v=rng();
    Tex_LoadOrUpdate(17,0,0,257,129,texture.data());
    unsigned checks=0;
    for (const auto [w,h]:{std::pair{641,479},std::pair{1920,1080},std::pair{2560,1440}})
    for (const bool bottom:{false,true})
    for (const int threads:{1,2,3})
    for (const bool shared:{false,true}) {
        test_threads=threads;
        test_pool.reset();
        if (shared && threads>1) test_pool=std::make_unique<RowPool>(threads);
        Tex_SetParallel(true);Tex_SetSharedPool(shared);
        std::vector<uint32_t> expected(size_t(w)*h),actual(expected.size());
        for (auto& v:expected) v=rng(); actual=expected;
        g_back_w=w;g_back_h=h;g_back_bottom_up=bottom;
        for (int layer=0;layer<16;++layer) {
            const uint32_t id=layer%3?17:999;
            const int x=layer%4?-23:11,y=layer%5?-7:13;
            const int dw=layer%4?w+47:71,dh=layer%5?h+31:39;
            const uint32_t color=layer==0?0u:(layer==1?0xffffffffu:rng());
            const float u0=-0.27f,v0=1.23f,u1=1.08f,v1=-0.12f;
            g_back_pixels=expected.data();reference_draw(id,x,y,dw,dh,u0,v0,u1,v1,color);
            g_back_pixels=actual.data();Tex_DrawRect(id,x,y,dw,dh,u0,v0,u1,v1,color);
            require(actual==expected);++checks;
        }
        Tex_ResetWorkers();test_pool.reset();
    }
    require(Tex_ParallelOperations()>0);
    unsigned copies=0;
    Tex_SetWriteCallback(+[](void* p) noexcept -> uint32_t* { ++*static_cast<unsigned*>(p);return g_back_pixels; },&copies);
    std::vector<uint32_t> out(64*64,0);g_back_pixels=out.data();g_back_w=g_back_h=64;
    Tex_DrawRect(999,0,0,64,64,0,0,1,1,0);
    Tex_DrawRect(999,80,0,64,64,0,0,1,1,0xffffffff);
    require(copies==0);
    Tex_DrawRect(999,0,0,64,64,0,0,1,1,0xffffffff);
    Tex_DrawRect(999,0,0,64,64,0,0,1,1,0xffffffff);
    require(copies==1);Tex_SetWriteCallback(nullptr,nullptr);
    Tex_Delete(17);
    std::cout << "Overlay reference RGBA checks=" << checks << " / orientation / clipped UV / layers / alpha / COW callback PASS\n";
    for (const auto [w,h]:{std::pair{1920,1080},std::pair{2560,1440}}) {
        texture.resize(257*129);for (auto& v:texture) v=rng();
        Tex_LoadOrUpdate(17,0,0,257,129,texture.data());
        out.assign(size_t(w)*h,0xff456789);g_back_pixels=out.data();g_back_w=w;g_back_h=h;g_back_bottom_up=false;
        for (int threads:{1,2,3}) {
            test_threads=threads;Tex_ResetWorkers();Tex_SetParallel(threads>1);Tex_SetSharedPool(false);
            for (int i=0;i<8;++i) Tex_DrawRect(17,0,0,w,h,0,0,1,1,0xbeabcdef);
            const auto start=std::chrono::steady_clock::now();
            for (int i=0;i<40;++i) Tex_DrawRect(17,0,0,w,h,0,0,1,1,0xbeabcdef);
            const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()/40;
            std::cout << "Synthetic textured rectangle " << w << "x" << h << " threads=" << threads << " ms=" << ms << "\n";
        }
        Tex_Delete(17);
    }
    Tex_ResetWorkers();
}
