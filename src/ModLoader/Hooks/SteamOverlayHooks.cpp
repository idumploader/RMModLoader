#include "SteamOverlayHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"
#include "../SteamOverlay/SteamOverlay.hpp"
#include "../SteamOverlay/GdiRender.hpp"
#include "../SteamOverlay/FrameBuffer.hpp"
#include "ParallelRenderer.hpp"
#include <chrono>
#include <stdexcept>

namespace rm_modloader {
namespace {
    steam_overlay::FrameBuffer frame;
    bool overlay_ready=false;
    uint64_t overlay_frames=0, capture_bytes=0, missing_frames=0;
    double overlay_ms=0, capture_ms=0;
    int optimization_mode=0;
    uint64_t borrowed_frames=0, materialized_frames=0;
    int capture_pitch=0;
    thread_local bool presenting=false;
    thread_local Screen* capture_screen=nullptr;
    using Pixels=unsigned char* (__thiscall*)(Surface*);
    using Stride=int (__thiscall*)(Surface*);
    Pixels get_pixels=nullptr;
    Stride get_stride=nullptr;
    using Clock=std::chrono::steady_clock;

    uint32_t* writable_frame(void*) noexcept {
        const auto begin=Clock::now();
        const bool borrowed=frame.borrowed();
        auto* pixels=frame.data();
        g_back_bottom_up=false;
        if (borrowed) {
            ++materialized_frames;
            capture_bytes+=uint64_t(g_back_w)*g_back_h*4;
            capture_ms+=std::chrono::duration<double,std::milli>(Clock::now()-begin).count();
        }
        return pixels;
    }

    struct ScreenHook : Screen {
        static int (__thiscall Screen::*original_update)(int,int);
        static int (__thiscall Screen::*original_draw)(HDC,int,int);
        int __thiscall update_hook(int target,int vsync) {
            struct Scope {
                bool previous=presenting;
                Scope() { presenting=true; }
                ~Scope() { presenting=previous; }
            } scope;
            return (this->*original_update)(target,vsync);
        }
        int __thiscall draw_hook(HDC target,int left,int top) {
            // Freeze and snap_to_bitmap use this entry too. Only native update
            // presents to the player; its inner renderer still has CPU pixels.
            if (!presenting || !overlay_ready || !target || capture_screen)
                return (this->*original_draw)(target,left,top);
            const int width=rect.right-rect.left, height=rect.bottom-rect.top;
            try { frame.begin(width,height); }
            catch (const std::exception&) {
                frame.clear(); ++missing_frames;
                return (this->*original_draw)(target,left,top);
            }
            capture_screen=this;
            struct Scope { ~Scope() { capture_screen=nullptr; } } scope;
            const int result=(this->*original_draw)(target,left,top);
            capture_screen=nullptr;
            if (!result || !frame.complete()) { ++missing_frames; return result; }
            const auto begin=Clock::now();
            // No readback from the DirectDraw/window DC. Capture assembled the
            // full frame in RAM before each source strip was recycled.
            Tex_SetWriteCallback(writable_frame,nullptr);
            struct WriteScope { ~WriteScope() { Tex_SetWriteCallback(nullptr,nullptr); } } write_scope;
            SteamOverlay_RenderFrame(const_cast<uint32_t*>(frame.read_data()),width,height,frame.read_bottom_up());
            ++overlay_frames;
            if (g_drew_this_frame) {
                BITMAPINFO info{};
                info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
                info.bmiHeader.biWidth=width;
                info.bmiHeader.biHeight=-height;
                info.bmiHeader.biPlanes=1;
                info.bmiHeader.biBitCount=32;
                info.bmiHeader.biCompression=BI_RGB;
                SetDIBitsToDevice(target,left,top,width,height,0,0,0,height,
                                 frame.data(),&info,DIB_RGB_COLORS);
            }
            overlay_ms+=std::chrono::duration<double,std::milli>(Clock::now()-begin).count();
            return result;
        }
    };
    int (__thiscall Screen::*ScreenHook::original_update)(int,int)=nullptr;
    int (__thiscall Screen::*ScreenHook::original_draw)(HDC,int,int)=nullptr;
}

uint64_t steam_overlay_frame_count() { return overlay_frames; }
double steam_overlay_render_ms() { return overlay_ms; }
bool steam_overlay_ready() { return overlay_ready; }
uint64_t steam_overlay_capture_bytes() { return capture_bytes; }
uint64_t steam_overlay_missing_frames() { return missing_frames; }
double steam_overlay_capture_ms() { return capture_ms; }
int steam_overlay_optimizations() { return optimization_mode; }
uint64_t steam_overlay_borrowed_frames() { return borrowed_frames; }
uint64_t steam_overlay_materialized_frames() { return materialized_frames; }
uint64_t steam_overlay_parallel_operations() { return Tex_ParallelOperations(); }
int steam_overlay_capture_pitch() { return capture_pitch; }
void configure_steam_overlay_optimizations(int mode) {
    if (mode<0 || mode>4) throw std::runtime_error("Expected overlay optimization mode 0..4");
    optimization_mode=mode;
    Tex_SetParallel(mode!=0);
    Tex_SetSharedPool(mode==1 || mode==3);
}

void capture_steam_overlay_surface(Screen* screen,Surface* source,int x,int y,RECT* clip) {
    if (!capture_screen || screen!=capture_screen || !source || x || y) return;
    const auto begin=Clock::now();
    const RECT region=clip ? *clip : screen->rect;
    const int width=region.right-region.left, height=region.bottom-region.top;
    const auto* info=source->info.bitmap;
    if (!info || info->bmiHeader.biBitCount!=32 || info->bmiHeader.biCompression!=BI_RGB ||
        info->bmiHeader.biWidth<width || info->bmiHeader.biHeight<height) return;
    capture_pitch=get_stride(source);
    bool borrowed=false;
    if (optimization_mode>=3 && region.left==screen->rect.left && region.top==screen->rect.top &&
        region.right==screen->rect.right && region.bottom==screen->rect.bottom) {
        auto owner=retain_completed_frame_surface(source);
        if (owner) borrowed=frame.borrow(get_pixels(source),capture_pitch,std::move(owner));
    }
    if (borrowed) ++borrowed_frames;
    else if (frame.append(region.left-screen->rect.left,region.top-screen->rect.top,
                     width,height,get_pixels(source),get_stride(source)))
        capture_bytes+=uint64_t(width)*height*4;
    const double duration=std::chrono::duration<double,std::milli>(Clock::now()-begin).count();
    capture_ms+=duration;
    overlay_ms+=duration;
}

void reset_steam_overlay_frame() {
    presenting=false; capture_screen=nullptr;
    Tex_SetWriteCallback(nullptr,nullptr);
    Tex_ResetWorkers();
    frame.clear();
    g_back_pixels=nullptr; g_back_w=g_back_h=0;
}

void apply_steam_overlay_hooks() {
    const auto* config=mod_loader->get_config().get("steam_overlay");
    if (!config || !config->get<bool>()) {
        mod_loader->log_info("Steam overlay disabled in config\n");
        return;
    }
    mod_loader->add_preinit_handler([] {
        if (!SteamOverlay_Init(mod_loader->get_game()->window_handle)) {
            mod_loader->log_error("Failed to init steam overlay!\n");
            return;
        }
        // Independent of the snapshot backend, including fast_render.
        get_pixels=at_offset<Pixels>(rgss_module,0x11f9f0);
        get_stride=at_offset<Stride>(rgss_module,0x007e30);
        overlay_ready=true;
        mod_loader->hook_method(0x10e660,&ScreenHook::update_hook,&ScreenHook::original_update);
        mod_loader->hook_method(0x10fb40,&ScreenHook::draw_hook,&ScreenHook::original_draw);
    });
    mod_loader->log_info("Applied steam overlay hooks\n");
}
}
