#define NOMINMAX
#include "RasterWorkers.hpp"
#include "RowPool.hpp"
#include "SnapshotExecution.hpp"
#include "../../ModLoader.hpp"
#include <array>
#include <algorithm>
#include <memory>

namespace rm_modloader::renderer {
namespace {
    std::unique_ptr<RowPool> pool;
    std::array<OwnedSurface,2> drawers;
    int count=1;
    using Draw=int (__thiscall*)(Surface*,RECT*,Surface*,RECT*,void*);
    using Fill=int (__thiscall*)(Surface*,RECT*,DWORD);
    Draw original_draw=nullptr;
    Fill original_fill=nullptr;
    thread_local bool inside_split=false;
    thread_local bool viewport_stretch=false;
    bool parallel_stretch=false;
    bool eligible(Surface* target,RECT& region) {
        if (!pool || inside_split || !snapshot_drawing() || !target || !target->info.bitmap ||
            target->info.bitmap->bmiHeader.biBitCount!=32 ||
            target->info.bitmap->bmiHeader.biCompression!=BI_RGB) return false;
        region=target->rect;
        return region.bottom-region.top>=count*8 && region.right>region.left &&
            int64_t(region.right-region.left)*(region.bottom-region.top)>=128*1024;
    }
    struct Operation {
        std::array<Surface,3> targets;
        RECT region,draw_rect,source_rect;
        Surface* source=nullptr;
        void* attributes=nullptr;
        DWORD color=0;
        bool fill=false;
        std::array<int,3> results{};
        std::array<bool,3> errors{};
        int bands=1;
    };
    void paint(void* context,int band) noexcept {
        struct Scope {
            bool previous=inside_split;
            Scope() { inside_split=true; }
            ~Scope() { inside_split=previous; }
        } scope;
        auto& work=*static_cast<Operation*>(context);
        auto& target=work.targets[band];
        const int height=work.region.bottom-work.region.top;
        target.rect.top=work.region.top+int(int64_t(height)*band/work.bands);
        target.rect.bottom=work.region.top+int(int64_t(height)*(band+1)/work.bands);
        try {
            work.results[band]=work.fill ? original_fill(&target,&work.draw_rect,work.color) :
                original_draw(&target,&work.draw_rect,work.source,&work.source_rect,work.attributes);
        } catch (...) { work.errors[band]=true; }
    }
    int execute(Operation& work,Surface* target) {
        work.bands=count;
        for (int i=0;i<count;++i) {
            work.targets[i]=*target;
            // Dynamic RGSS kernels own mutable executable code + a critical
            // section. Each helper needs its own drawer, not the shared target's.
            if (i) {
                work.targets[i].dynamic_draw=drawers[i-1]->dynamic_draw;
                work.targets[i].custom_draw=drawers[i-1]->custom_draw;
            }
        }
        pool->run(&paint,&work);
        if (std::any_of(work.errors.begin(),work.errors.begin()+count,[](bool value){return value;}))
            throw std::runtime_error("Raster worker draw failed");
        return std::any_of(work.results.begin(),work.results.begin()+count,[](int result){return result!=0;});
    }
    int __fastcall draw_hook(Surface* target,void*,RECT* rect,Surface* source,RECT* src,void* attributes) {
        RECT region;
        if (!target || !source || source==target || !attributes ||
            (source->image.buffer_bits && source->image.buffer_bits==target->image.buffer_bits) ||
            !eligible(target,region)) return original_draw(target,rect,source,src,attributes);
        const auto* info=source->info.bitmap;
        if (!info || info->bmiHeader.biBitCount!=32) return original_draw(target,rect,source,src,attributes);
        RECT destination=rect ? *rect : RECT{0,0,target->info.bitmap->bmiHeader.biWidth,target->info.bitmap->bmiHeader.biHeight};
        RECT input=src ? *src : RECT{0,0,info->bmiHeader.biWidth,info->bmiHeader.biHeight};
        const bool scaled=destination.right-destination.left!=input.right-input.left ||
            destination.bottom-destination.top!=input.bottom-input.top;
        // Preserve the full input/output rectangles for every band: RGSS's
        // fixed-point clipper computes the global sampling phase. Only captured
        // viewport alpha-stretch is enabled, not general sprite transformations.
        if (destination.right<=destination.left || destination.bottom<=destination.top ||
            int64_t(destination.right-destination.left)*(destination.bottom-destination.top)<128*1024 ||
            (scaled && !(viewport_stretch && parallel_stretch &&
                *static_cast<DWORD*>(attributes)==0x10000u)) ||
            (*static_cast<DWORD*>(attributes)&0xc000u))
            return original_draw(target,rect,source,src,attributes);
        Operation work;
        work.region=region; work.draw_rect=destination; work.source_rect=input;
        work.source=source; work.attributes=attributes;
        return execute(work,target);
    }
    int __fastcall fill_hook(Surface* target,void*,RECT* rect,DWORD color) {
        RECT region;
        if (!eligible(target,region)) return original_fill(target,rect,color);
        Operation work;
        work.region=region;
        work.draw_rect=rect ? *rect : RECT{0,0,target->info.bitmap->bmiHeader.biWidth,target->info.bitmap->bmiHeader.biHeight};
        if (work.draw_rect.right<=work.draw_rect.left || work.draw_rect.bottom<=work.draw_rect.top ||
            int64_t(work.draw_rect.right-work.draw_rect.left)*(work.draw_rect.bottom-work.draw_rect.top)<128*1024)
            return original_fill(target,rect,color);
        work.color=color; work.fill=true;
        return execute(work,target);
    }
}
void install_raster_workers() {
    mod_loader->hook_function(0x10bb00,reinterpret_cast<Draw>(&draw_hook),&original_draw);
    mod_loader->hook_function(0x10c450,reinterpret_cast<Fill>(&fill_hook),&original_fill);
}
void ensure_raster_workers() {
    if (count>1 && !pool) {
        std::array<OwnedSurface,2> fresh;
        for (int i=1;i<count;++i) fresh[i-1]=make_surface(1,1);
        auto workers=std::make_unique<RowPool>(count);
        drawers=std::move(fresh); pool=std::move(workers);
    }
}
void set_raster_worker_count(int value) { reset_raster_workers(); count=value; }
void reset_raster_workers() { pool.reset(); for (auto& drawer:drawers) drawer.reset(); }
void set_parallel_stretch(bool value) { parallel_stretch=value; }
int raster_thread_count() { return count; }
bool run_shared_raster_bands(void (*function)(void*,int) noexcept,void* context) {
    if (!pool) return false;
    pool->run(function,context);
    return true;
}
int draw_viewport_stretch(Surface* target,RECT* rect,Surface* source,RECT* input,void* attrs) {
    struct Scope {
        bool previous=viewport_stretch;
        Scope() { viewport_stretch=true; }
        ~Scope() { viewport_stretch=previous; }
    } scope;
    return draw_hook(target,nullptr,rect,source,input,attrs);
}
}
