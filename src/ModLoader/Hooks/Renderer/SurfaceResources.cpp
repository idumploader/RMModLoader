#include "SurfaceResources.hpp"
#include "MemoryBudget.hpp"
#include "../../RMGlobal.hpp"
#include "../../Hook.hpp"
#include "../HRFixHooks.hpp"
#include <cstring>
#include <stdexcept>

namespace rm_modloader::renderer {
namespace {
    using Walk = void* (__thiscall*)(Sprite*, Surface*, DWORD*, int*, RECT*);
    using New = void* (__cdecl*)(unsigned int);
    using SurfaceCtor = Surface* (__thiscall*)(Surface*, int);
    using SurfaceInit = int (__thiscall*)(Surface*, int, int);
    using SurfaceFree = void* (__thiscall*)(Surface*, char);
    using Pixels = unsigned char* (__thiscall*)(Surface*);
    using Stride = int (__thiscall*)(Surface*);

    Walk walk;
    New allocate;
    SurfaceCtor surface_ctor;
    SurfaceInit surface_init;
    SurfaceFree surface_free;
    Pixels get_pixels;
    Stride get_stride;
    bool tilemap_hrfix=false;
}
void initialize_surface_resources(bool hrfix) {
    tilemap_hrfix=hrfix;
    walk=at_offset<Walk>(rgss_module,0x110820);
    allocate=at_offset<New>(rgss_module,0x17e979);
    surface_ctor=at_offset<SurfaceCtor>(rgss_module,0x10b120);
    surface_init=at_offset<SurfaceInit>(rgss_module,0x10b3b0);
    surface_free=at_offset<SurfaceFree>(rgss_module,0x10b280);
    get_pixels=at_offset<Pixels>(rgss_module,0x11f9f0);
    get_stride=at_offset<Stride>(rgss_module,0x007e30);
}
bool surface_resources_ready() { return get_pixels!=nullptr; }
unsigned char* pixels(Surface* surface) { return get_pixels(surface); }
int stride(Surface* surface) { return get_stride(surface); }
void render_walk(Sprite* root,Surface* destination,DWORD* origin,int* offset,RECT* clip) {
    walk(root,destination,origin,offset,clip);
}
void SurfaceDeleter::operator()(Surface* p) const {
    if (p) { surface_free(p,1); renderer_bytes.fetch_sub(bytes); }
}
OwnedSurface make_surface(int width,int height) {
    // HRFix expands this special strip size inside the hooked initializer.
    // Reserve its actual storage before that initializer allocates it.
    if (tilemap_hrfix && width==hrfix_render_width && height==41)
        height=hrfix_render_height;
    const size_t bytes=size_t(width)*height*4+sizeof(Surface);
    MemoryCharge reservation;
    reservation.add(bytes);
    auto* memory=static_cast<Surface*>(allocate(sizeof(Surface)));
    if (!memory) throw std::bad_alloc();
    OwnedSurface result(surface_ctor(memory,32),SurfaceDeleter{bytes});
    reservation.bytes=0;
    if (!surface_init(result.get(),width,height))
        throw std::runtime_error("Cannot allocate renderer surface");
    return result;
}

void SurfaceCache::clear() {
    // Destruction calls the lifetime hook: detach entries before releasing them.
    decltype(entries_) old;
    old.swap(entries_);
    statistics_.bytes=0;
}
void SurfaceCache::invalidate(Surface* source) {
    auto found=entries_.find(source);
    if (found==entries_.end()) return;
    auto keep_alive=std::move(found->second.surface);
    statistics_.bytes-=found->second.bytes;
    entries_.erase(found);
}
void SurfaceCache::reset_counters() {
    statistics_.copied_bytes=statistics_.hits=statistics_.misses=0;
}
SharedSurface SurfaceCache::copy(Surface* source,bool source_tree,bool enabled) {
    const auto* info=source->info.bitmap;
    if (!info || info->bmiHeader.biBitCount!=32 || info->bmiHeader.biCompression!=BI_RGB)
        throw std::runtime_error("Only 32-bit BI_RGB surfaces are supported");
    const int w=info->bmiHeader.biWidth,h=info->bmiHeader.biHeight;
    if (w<=0 || h<=0 || w>16384 || h>16384)
        throw std::runtime_error("Unsupported surface dimensions/orientation");
    const size_t bytes=size_t(w)*size_t(h)*4;
    if (source_tree && enabled) {
        auto cached=entries_.find(source);
        if (cached!=entries_.end()) {
            auto* c=cached->second.surface.get();
            if (c->info.bitmap->bmiHeader.biWidth==w && c->info.bitmap->bmiHeader.biHeight==h &&
                c->left_offset==source->left_offset && c->top_offset==source->top_offset &&
                std::memcmp(&c->rect,&source->rect,sizeof(RECT))==0) {
                ++statistics_.hits;
                return cached->second.surface;
            }
            invalidate(source);
        }
    }
    auto target=make_surface(w,h);
    const int src_stride = stride(source), dst_stride = stride(target.get());
    auto* src = pixels(source);
    auto* dst = pixels(target.get());
    if (!src || !dst || src_stride == 0 || dst_stride == 0 ||
        (src_stride > -w * 4 && src_stride < w * 4) ||
        (dst_stride > -w * 4 && dst_stride < w * 4))
        throw std::runtime_error("Invalid surface pixel layout");
    for (int y = 0; y < h; ++y)
        std::memcpy(dst + ptrdiff_t(y) * dst_stride, src + ptrdiff_t(y) * src_stride, size_t(w) * 4);
    target->left_offset = source->left_offset;
    target->top_offset = source->top_offset;
    target->rect = source->rect;
    SharedSurface shared(std::move(target));
    if (source_tree) {
        statistics_.copied_bytes += bytes;
        ++statistics_.misses;
        if (enabled) {
            if (statistics_.bytes > max_pixel_bytes || bytes > max_pixel_bytes - statistics_.bytes)
                clear();
            entries_.emplace(source, Entry{shared, bytes});
            statistics_.bytes += bytes;
        }
    }
    return shared;
}
}
