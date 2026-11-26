#include "SnapshotReplay.hpp"
#include "SnapshotExecution.hpp"
#include "../../Hook.hpp"
#include "../../RMGlobal.hpp"
#include <cstring>
#include <algorithm>
namespace rm_modloader::renderer {
    using TileDraw = void (__thiscall*)(RxTilemapSprite*, Surface*, int, int, int);
    using ShadowDraw = int (__stdcall*)(Surface*, int, int, char);
    using FlashDraw = int (__thiscall*)(Surface*, RECT*, Surface*, RECT*, void*);
    TileDraw tile_draw, table_edge_draw;
    ShadowDraw shadow_draw;
    FlashDraw flash_draw;
    std::array<void*, 12> tile_vtable{};
    std::array<void*, 12> plane_vtable{};
    using SurfaceDraw = int (__thiscall*)(Surface*, RECT*, Surface*, RECT*, void*);
    SurfaceDraw surface_draw;

    // RGSS Plane 0x1c7f0, with the viewport origin baked into ox/oy at capture.
    // No lookup in the global live viewport registry is performed by the worker.
    int __fastcall draw_plane_snapshot(RxPlane* self, void*, Surface* dest, RECT*) {
        if (!self->surface90) return 1;
        const auto source_rect = at_address<RECT>(self, 0x100);
        const int width = int((source_rect.right-source_rect.left)*self->doubleD8);
        const int height = int((source_rect.bottom-source_rect.top)*self->doubleE0);
        if (!width || !height) return 1;
        alignas(4) unsigned char attrs[0x38];
        std::memcpy(attrs, reinterpret_cast<unsigned char*>(self)+0x94, sizeof(attrs));
        auto& blend = at_address<DWORD>(attrs,0);
        const int gray = at_address<int>(self,0xf4);
        if (gray > 0) { blend |= 0x80000; at_address<int>(attrs,0x2c)=gray; }
        const int red=at_address<int>(self,0xe8), green=at_address<int>(self,0xec), blue=at_address<int>(self,0xf0);
        if (red || green || blue) {
            blend |= 0x100;
            const int rgb[3]{blue,green,red};
            for (int i=0;i<3;++i) {
                at_address<int16_t>(attrs,0x1c+2*i)=int16_t((std::max)(rgb[i],0));
                at_address<int16_t>(attrs,0x24+2*i)=int16_t((std::max)(-rgb[i],0));
            }
            at_address<int16_t>(attrs,0x22)=at_address<int16_t>(attrs,0x2a)=0;
        }
        const DWORD color=at_address<DWORD>(self,0xf8);
        if (color >> 24) { blend |= 0x40; at_address<DWORD>(attrs,8)=color; }
        auto mod = [](int n,int d) { const int r=n%d; return r<0 ? r+d : r; };
        const int ox=mod(at_address<int>(self,0xcc),width), oy=mod(at_address<int>(self,0xd0),height);
        for (int64_t y=-oy;y<self->rect.bottom;y+=height) {
            for (int64_t x=-ox;x<self->rect.right;x+=width) {
                RECT rect{LONG(x),LONG(y),LONG(x+width),LONG(y+height)};
                if (!surface_draw(dest,&rect,self->surface90,nullptr,attrs)) return 0;
            }
        }
        return 1;
    }

    // Independent loop: never enters HRFix's self-modifying 0x21d40 loop.
    // Helpers 0x212f0 / 0x219e0 use immutable pattern tables and this snapshot's
    // map/flags/frame/atlases; all destination state belongs to this job.
    int __fastcall draw_tile_snapshot(TileSpriteSnapshot* self, void*, Surface* dest, RECT* clip) {
        struct Timing {
            Clock::time_point start=Clock::now();
            ~Timing() { record_worker_tilemap(std::chrono::duration<double,std::milli>(Clock::now()-start).count()); }
        } timing;
        const auto* map = self->tilemap;
        if (!map->map_data) return 1;
        auto get = [map](int x, int y, unsigned z) -> int {
            if (x < 0 || y < 0 || x >= int(map->width) || y >= int(map->height) || z >= 4) return -1;
            return map->map_data[x + size_t(map->width) * (y + size_t(map->height) * z)];
        };
        auto flags = [map](int id) -> int {
            return unsigned(id) < map->flags_count ? map->flags[id] : 0;
        };
        auto table = [&flags](int id) { return id >= 2816 && id < 4352 && (flags(id) & 0x80); };
        const auto* flash = map->flash_data;
        const int fw = int(map->flash_data_width), fh = int(map->flash_data_height);
        const unsigned frame = map->frame_count;
        for (int y = 0; y < self->rows; ++y) {
            if (32*y < clip->top-32 || 32*y >= clip->bottom) continue;
            const int my = y + int(map->offset_y_tiles);
            if (my < 0) continue;
            for (int x = 0; x < self->columns; ++x) {
                const int mx = x + int(map->offset_x_tiles);
                if (mx < 0) continue;
                const int tx = mx % int(map->width), ty = my % int(map->height);
                if (!self->unkD0) {
                    const int a = get(tx, ty, 0), b = get(tx, ty, 1);
                    tile_draw(self, dest, x*32, y*32, a);
                    tile_draw(self, dest, x*32, y*32, b);
                    shadow_draw(dest, x*32, y*32, char(get(tx, ty, 3)));
                    if (!(a >= 4352 && a < 8192) && !table(b)) {
                        const int above = get(tx, ty-1, 1);
                        if (table(above)) table_edge_draw(self, dest, x*32, y*32, above);
                    }
                }
                const int upper = get(tx, ty, 2);
                const bool star = (flags(upper) & 0x10) != 0;
                if ((!self->unkD0 && !star) || (self->unkD0 == 1 && star))
                    tile_draw(self, dest, x*32, y*32, upper);
                const int color = flash ? flash[mx % fw + size_t(fw) * (my % fh)] : 0;
                if (color > 0) {
                    alignas(4) unsigned char attrs[0x38]{};
                    at_address<int>(attrs, 0) = 2;
                    for (int i = 0; i < 3; ++i) at_address<int16_t>(attrs, 8+i*2) = 128;
                    int pulse = (frame >> 2) % 8;
                    if (pulse >= 4) pulse = 8-pulse;
                    pulse += 4;
                    at_address<int16_t>(attrs, 0x14) = int16_t(pulse * ((color & 0xf00) >> 5) / 8);
                    at_address<int16_t>(attrs, 0x12) = int16_t(pulse * ((color & 0xf0) >> 1) / 8);
                    at_address<int16_t>(attrs, 0x10) = int16_t(pulse * (8*(color & 0xf)) / 8);
                    RECT rect{x*32, y*32, x*32+32, y*32+32};
                    flash_draw(dest, &rect, nullptr, nullptr, attrs);
                }
            }
        }
        return 1;
    }

void initialize_snapshot_replay() {
    tile_draw = at_offset<TileDraw>(rgss_module, 0x212f0);
    table_edge_draw = at_offset<TileDraw>(rgss_module, 0x219e0);
    shadow_draw = at_offset<ShadowDraw>(rgss_module, 0x21b70);
    flash_draw = at_offset<FlashDraw>(rgss_module, 0x10c250);
    std::memcpy(tile_vtable.data(), at_offset<void*>(rgss_module, 0x1a91ec), sizeof(tile_vtable));
    tile_vtable[9] = reinterpret_cast<void*>(&draw_tile_snapshot);
    surface_draw = at_offset<SurfaceDraw>(rgss_module,0x10bb00);
    std::memcpy(plane_vtable.data(),at_offset<void*>(rgss_module,0x1a8b40),sizeof(plane_vtable));
    plane_vtable[9]=reinterpret_cast<void*>(&draw_plane_snapshot);
}
}
