#define NOMINMAX
#include "RenderIntegration.hpp"
#include "ParallelRenderer.hpp"
#include "MapFrameProbe.hpp"
#include "SteamOverlayHooks.hpp"
#include "Renderer/RendererService.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"
#include <chrono>
#include <cstring>

namespace rm_modloader {
namespace {
    thread_local bool in_graphics_update = false;
    RubyValue (__cdecl* original_update)(RubyValue);
    using RenderEntry=int (__thiscall*)(Screen*,Surface*,int,int,RECT*);
    using SurfaceDC=HDC (__thiscall*)(Surface*);
    using ReleaseDC=DWORD (__thiscall*)(Surface*);
    using Pixels=unsigned char* (__thiscall*)(Surface*);
    using Stride=int (__thiscall*)(Surface*);
    RenderEntry render_entry;
    SurfaceDC surface_dc;
    ReleaseDC release_dc;
    Pixels pixels;
    Stride stride;

    RubyValue __cdecl update_hook(RubyValue self) {
        struct UpdateScope {
            bool previous = in_graphics_update;
            UpdateScope() { in_graphics_update = true; }
            ~UpdateScope() { in_graphics_update = previous; }
        } scope;
        return original_update(self);
    }

    struct ScreenRenderHook : Screen {
        static int (__thiscall Screen::* original_render)(Surface*, int, int, RECT*);
        int __thiscall render_hook(Surface* destination, int x, int y, RECT* rect) {
            if (!in_graphics_update) preserve_last_frame_before_render();
            const auto render = [&] {
                if (in_graphics_update && render_snapshot_frame(this, destination, x, y, rect)) {
                    auto* output=direct_frame_output_surface();
                    if (!output) output=destination;
                    remember_screen_frame(this, output, x, y, rect, true);
                    capture_steam_overlay_surface(this, output, x, y, rect);
                    return 1;
                }
                const int result = (this->*original_render)(destination, x, y, rect);
                if (in_graphics_update && result)
                    remember_screen_frame(this, destination, x, y, rect, false);
                if (result) capture_steam_overlay_surface(this, destination, x, y, rect);
                return result;
            };
            if (!map_frame_probe_capture_enabled()) return render();
            const auto begin = std::chrono::steady_clock::now();
            const int result = render();
            map_frame_probe_rendered(std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - begin).count());
            return result;
        }
    };
    int (__thiscall Screen::* ScreenRenderHook::original_render)(Surface*, int, int, RECT*) = nullptr;

    struct DirectOutputHook : Screen {
        static int (__thiscall Screen::* original)(RECT*,int,int,HDC*);
        int __thiscall output_hook(RECT* region,int left,int top,HDC* context) {
            // Strip renderers and snapshot/freeze retain the original path.
            if (!in_graphics_update || !renderer::service::direct_output() || !context || !region ||
                std::memcmp(region,&rect,sizeof(RECT)) || !surface || !surface->info.bitmap ||
                surface->info.bitmap->bmiHeader.biWidth!=rect.right-rect.left ||
                surface->info.bitmap->bmiHeader.biHeight!=rect.bottom-rect.top)
                return (this->*original)(region,left,top,context);
            begin_direct_frame_output();
            struct Scope { ~Scope() { end_direct_frame_output(); } } scope;
            render_entry(this,surface,0,0,region);
            auto* output=direct_frame_output_surface();
            HDC source=context[1];
            HDC borrowed=output ? surface_dc(output) : nullptr;
            if (borrowed) source=borrowed;
            else if (output) {
                // Failed DC acquisition: materialize into the engine surface.
                auto* dst=pixels(surface); const auto* src=pixels(output);
                const int dp=stride(surface),sp=stride(output);
                const int width=rect.right-rect.left,height=rect.bottom-rect.top;
                for (int y=0;y<height;++y)
                    std::memcpy(dst+ptrdiff_t(y)*dp,src+ptrdiff_t(y)*sp,size_t(width)*4);
            }
            const int result=BitBlt(context[0],left+region->left,top+region->top,
                region->right-region->left,region->bottom-region->top,source,0,0,SRCCOPY);
            if (borrowed) {
                // Finish all GDI reads before a released target can be recycled
                // and written by the worker on a later update.
                GdiFlush();
                release_dc(output);
            }
            validate_direct_frame_output(context[0],left,top,result);
            return result;
        }
    };
    int (__thiscall Screen::* DirectOutputHook::original)(RECT*,int,int,HDC*)=nullptr;

    struct PresentationHook : Screen {
        static int (__thiscall Screen::* original_draw)(HDC, int, int);
        int __thiscall draw_hook(HDC target, int left, int top) {
            if (in_graphics_update) begin_last_frame_presentation();
            begin_snapshot_presentation();
            const int result = (this->*original_draw)(target, left, top);
            end_snapshot_presentation(target, left, top, result);
            if (in_graphics_update) end_last_frame_presentation(result);
            return result;
        }
    };
    int (__thiscall Screen::* PresentationHook::original_draw)(HDC, int, int) = nullptr;
}

void reset_render_integration() {
    // RGSSReset uses a Ruby longjmp, which can bypass UpdateScope's destructor.
    in_graphics_update = false;
    end_direct_frame_output();
}

void apply_render_integration() {
    // Install the scope before the diagnostic update hook, so both native render
    // and presentation callbacks see the same Graphics.update boundary.
    mod_loader->hook_function(0xb080, &update_hook, &original_update);
    mod_loader->hook_method(0x110be0, &ScreenRenderHook::render_hook, &ScreenRenderHook::original_render);
    mod_loader->hook_method(0x10fb40, &PresentationHook::draw_hook, &PresentationHook::original_draw);
    render_entry=at_offset<RenderEntry>(rgss_module,0x110be0);
    surface_dc=at_offset<SurfaceDC>(rgss_module,0x10b6a0);
    release_dc=at_offset<ReleaseDC>(rgss_module,0x10b720);
    pixels=at_offset<Pixels>(rgss_module,0x11f9f0);
    stride=at_offset<Stride>(rgss_module,0x007e30);
    mod_loader->hook_method(0x10fd90,&DirectOutputHook::output_hook,&DirectOutputHook::original);
}
}
