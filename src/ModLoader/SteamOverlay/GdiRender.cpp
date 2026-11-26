#define NOMINMAX
#include "GdiRender.hpp"
#include "../Hooks/Renderer/RasterWorkers.hpp"
#include "../Hooks/Renderer/RowPool.hpp"
#include <memory>
#include <algorithm>
#include <cmath>

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

	FILE* f = nullptr; fopen_s(&f, filename, "wb");
	if (!f) return;
	fwrite(&bfh, sizeof(bfh), 1, f);
	fwrite(&bih, sizeof(bih), 1, f);
	fwrite(pixels, bih.biSizeImage, 1, f);
	fclose(f);
}


namespace {
    bool parallel=false,shared_pool=true;
    int own_threads=0;
    std::unique_ptr<rm_modloader::renderer::RowPool> own_pool;
    uint64_t parallel_operations=0;
    OverlayWriteCallback write_callback=nullptr;
    void* write_context=nullptr;
}
bool Tex_Has(uint32_t id) { return g_textures.find(id)!=g_textures.end(); }
void Tex_SetWriteCallback(OverlayWriteCallback callback,void* context) { write_callback=callback;write_context=context; }
void Tex_SetParallel(bool value) { parallel=value; if (!value) Tex_ResetWorkers(); }
void Tex_SetSharedPool(bool value) { shared_pool=value; }
bool Tex_ParallelEnabled() { return parallel; }
bool Tex_SharedPoolEnabled() { return shared_pool; }
uint64_t Tex_ParallelOperations() { return parallel_operations; }
void Tex_ResetWorkers() { own_pool.reset(); own_threads=0; }

namespace {
struct RectWork {
    uint32_t* pixels;
    const uint32_t* tpx;
    int width,height,tw,th,dx,dy,x0,x1,y0,y1,bands;
    int c_a,c_r,c_g,c_b;
    float u0,v0,u_per_dx,v_per_dy;
    bool bottom_up;
};
void paint_rows(void* context,int band) noexcept {
    const auto& work=*static_cast<const RectWork*>(context);
    const auto& [pixels,tpx,width,height,tw,th,dx,dy,x0,x1,y0,y1,bands,c_a,c_r,c_g,c_b,u0,v0,u_per_dx,v_per_dy,bottom_up]=work;
    const int first=y0+int(int64_t(y1-y0)*band/bands);
    const int last=y0+int(int64_t(y1-y0)*(band+1)/bands);
	for (int py = first; py < last; ++py) {
		const float v  = v0 + (py - dy + 0.5f) * v_per_dy;
		int   sy = (int)(v * th);
		if (tw && th) {
			if (sy < 0)        sy = 0;
			else if (sy >= th) sy = th - 1;
		}

		const int dst_y = bottom_up ? (height - 1 - py) : py;
		uint32_t* dst_row = pixels + (size_t)dst_y * width;

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
}
void Tex_DrawRect(uint32_t textureID,int dx,int dy,int dw,int dh,
                  float u0,float v0,float u1,float v1,uint32_t color) {
    if (!g_back_pixels || dw<=0 || dh<=0 || !(color>>24)) return;
    const int x0=std::max(dx,0),y0=std::max(dy,0);
    const int x1=int(std::min(int64_t(dx)+dw,int64_t(g_back_w)));
    const int y1=int(std::min(int64_t(dy)+dh,int64_t(g_back_h)));
    if (x0>=x1 || y0>=y1) return;
    if (write_callback) {
        g_back_pixels=write_callback(write_context);
        write_callback=nullptr;write_context=nullptr;
        if (!g_back_pixels) return;
    }
    auto found=g_textures.find(textureID);
    const auto* texture=found==g_textures.end() ? nullptr : &found->second;
    RectWork work{g_back_pixels,texture ? static_cast<const uint32_t*>(texture->dib_pixels) : nullptr,
        g_back_w,g_back_h,texture ? texture->width : 0,texture ? texture->height : 0,
        dx,dy,x0,x1,y0,y1,1,int(color>>24),int((color>>16)&255),int((color>>8)&255),int(color&255),
        u0,v0,(u1-u0)/float(dw),(v1-v0)/float(dh),g_back_bottom_up};
    g_drew_this_frame=true;
    const int threads=rm_modloader::renderer::raster_thread_count();
    if (parallel && threads>1 && int64_t(x1-x0)*(y1-y0)>=128*1024 && y1-y0>=threads*8) {
        work.bands=threads;
        if (shared_pool && rm_modloader::renderer::run_shared_raster_bands(&paint_rows,&work)) {
            Tex_ResetWorkers();
            ++parallel_operations;return;
        }
        if (!own_pool || own_threads!=threads) {
            try {
                own_pool=std::make_unique<rm_modloader::renderer::RowPool>(threads);
                own_threads=threads;
            } catch (...) { work.bands=1;paint_rows(&work,0);return; }
        }
        own_pool->run(&paint_rows,&work);++parallel_operations;
    } else paint_rows(&work,0);
}

void Tex_DrawQuad(uint32_t textureID,const OverlayVertex* v) {
    if(!g_back_pixels || !v)return;
    if(!((v[0].color|v[1].color|v[2].color|v[3].color)>>24))return;
    for(int i=0;i<4;++i)if(!std::isfinite(v[i].x) || !std::isfinite(v[i].y) ||
        !std::isfinite(v[i].u) || !std::isfinite(v[i].v))return;
    // Common axis-aligned Steam UI quads use the existing parallel rectangle path.
    if(v[0].x==v[3].x && v[1].x==v[2].x && v[0].y==v[1].y && v[2].y==v[3].y &&
       v[0].u==v[3].u && v[1].u==v[2].u && v[0].v==v[1].v && v[2].v==v[3].v &&
       v[0].color==v[1].color && v[0].color==v[2].color && v[0].color==v[3].color &&
       v[0].x>=-32768 && v[1].x<=32768 && v[0].y>=-32768 && v[2].y<=32768 &&
       v[0].x==std::floor(v[0].x) && v[1].x==std::floor(v[1].x) &&
       v[0].y==std::floor(v[0].y) && v[2].y==std::floor(v[2].y) &&
       v[1].x>v[0].x && v[2].y>v[0].y) {
        Tex_DrawRect(textureID,int(v[0].x),int(v[0].y),int(v[1].x-v[0].x),int(v[2].y-v[0].y),
            v[0].u,v[0].v,v[2].u,v[2].v,v[0].color);return;
    }
    float left=v[0].x,right=left,top=v[0].y,bottom=top;
    for(int i=1;i<4;++i) { left=std::min(left,v[i].x);right=std::max(right,v[i].x);
        top=std::min(top,v[i].y);bottom=std::max(bottom,v[i].y); }
    const int x0=int(std::floor(std::clamp(left,0.f,float(g_back_w))));
    const int x1=int(std::ceil(std::clamp(right,0.f,float(g_back_w))));
    const int y0=int(std::floor(std::clamp(top,0.f,float(g_back_h))));
    const int y1=int(std::ceil(std::clamp(bottom,0.f,float(g_back_h))));
    if(x0>=x1 || y0>=y1)return;
    if(write_callback) { g_back_pixels=write_callback(write_context);write_callback=nullptr;write_context=nullptr;
        if(!g_back_pixels)return; }
    auto found=g_textures.find(textureID);
    const auto* tex=found==g_textures.end()?nullptr:&found->second;
    auto edge=[](const OverlayVertex& a,const OverlayVertex& b,float x,float y) {
        return (b.x-a.x)*(y-a.y)-(b.y-a.y)*(x-a.x); };
    auto top_left=[](const OverlayVertex& a,const OverlayVertex& b) {
        return b.y<a.y || (b.y==a.y && b.x>a.x); };
    for(int triangle=0;triangle<2;++triangle) {
        OverlayVertex a=v[0],b=v[triangle+1],c=v[triangle+2];
        float area=edge(a,b,c.x,c.y);
        if(!std::isfinite(area) || area==0)continue;
        if(area<0) { std::swap(b,c);area=-area; }
        for(int y=y0;y<y1;++y)for(int x=x0;x<x1;++x) {
            const float e0=edge(b,c,x+.5f,y+.5f),e1=edge(c,a,x+.5f,y+.5f),e2=edge(a,b,x+.5f,y+.5f);
            if(e0<0 || (e0==0 && !top_left(b,c)) || e1<0 || (e1==0 && !top_left(c,a)) ||
               e2<0 || (e2==0 && !top_left(a,b)))continue;
            const float w0=e0/area,w1=e1/area,w2=e2/area;
            uint32_t sample=0xffffffff;
            if(tex) {
                const float u=std::clamp(w0*a.u+w1*b.u+w2*c.u,0.f,1.f);
                const float t=std::clamp(w0*a.v+w1*b.v+w2*c.v,0.f,1.f);
                const int sx=std::min(int(u*tex->width),tex->width-1),sy=std::min(int(t*tex->height),tex->height-1);
                sample=static_cast<const uint32_t*>(tex->dib_pixels)[size_t(sy)*tex->width+sx];
            }
            int modulation[4];
            for(int k=0;k<4;++k)modulation[k]=std::clamp(int(w0*((a.color>>(8*k))&255)+
                w1*((b.color>>(8*k))&255)+w2*((c.color>>(8*k))&255)+.5f),0,255);
            const int alpha=(((sample>>24)&255)*modulation[3]+127)/255;
            if(!alpha)continue;
            auto& pixel=g_back_pixels[size_t(g_back_bottom_up?g_back_h-1-y:y)*g_back_w+x];
            uint32_t out=0xff000000;
            for(int k=0;k<3;++k) {
                const int src=(((sample>>(8*k))&255)*modulation[k]+127)/255;
                out|=uint32_t((src*alpha+((pixel>>(8*k))&255)*(255-alpha)+127)/255)<<(8*k);
            }
            pixel=out;g_drew_this_frame=true;
        }
    }
}
