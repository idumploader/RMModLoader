#define NOMINMAX
#include "SnapshotCapture.hpp"
#include "SnapshotReplay.hpp"
#include "../ViewportEffectsHooks.hpp"
#include "../HRFixHooks.hpp"
#include "../../Hook.hpp"
#include <cstring>
#include <cmath>
#include <climits>
#include <algorithm>

namespace rm_modloader::renderer {
namespace { constexpr size_t max_table_bytes=64*1024*1024; }
        RxTilemap* Snapshot::copy_tilemap(const CaptureContext& context,const RxTilemap* source) {
            if (!source) throw std::runtime_error("Missing Tilemap state");
            auto found = tilemaps.find(source);
            if (found != tilemaps.end()) return &found->second->value;
            auto owned = std::make_unique<TileState>();
            auto* state = owned.get();
            state->memory.add(sizeof(TileState));
            state->value = *source;
            auto& copy = state->value;
            copy.viewport = nullptr;
            copy.tilemap_sprite8 = copy.tilemap_spriteC = nullptr;
            auto table_copy = [&](const int16_t* data, size_t count, std::vector<int16_t>& target) -> int16_t* {
                if (!data) return nullptr;
                if (count > (max_table_bytes-table_bytes)/sizeof(int16_t))
                    throw std::runtime_error("Snapshot exceeds 64 MiB of Tilemap tables");
                state->memory.add(count*sizeof(int16_t));
                target.assign(data, data+count);
                table_bytes += count*sizeof(int16_t);
                return target.data();
            };
            auto cells = [](DWORD w, DWORD h, DWORD d) -> size_t {
                if (!w || !h || !d || w > 16384 || h > 16384 || d > 16)
                    throw std::runtime_error("Unsupported Tilemap table dimensions");
                const uint64_t count = uint64_t(w)*h*d;
                if (count > max_table_bytes/2) throw std::runtime_error("Oversized Tilemap table");
                return size_t(count);
            };
            if (source->map_data && source->depth < 4)
                throw std::runtime_error("Tilemap map_data must have at least four layers");
            copy.map_data = table_copy(source->map_data, source->map_data ? cells(source->width,source->height,source->depth) : 0, state->map);
            copy.flags = table_copy(source->flags, source->flags_count, state->flags);
            if (!copy.flags) copy.flags_count = 0;
            const auto* flash = source->flash_data;
            copy.flash_data = table_copy(flash, flash ? cells(source->flash_data_width,source->flash_data_height,source->flash_data_depth) : 0, state->flash);
            for (int i=0; i<9; ++i) copy.tilesets_surfaces[i] = copy_surface(context,source->tilesets_surfaces[i]);
            tilemaps.emplace(source, std::move(owned));
            node_bytes += sizeof(TileState);
            return &state->value;
        }

        Surface* Snapshot::copy_surface(const CaptureContext& context,Surface* source) {
            if (!source) return nullptr;
            auto found = surfaces.find(source);
            if (found != surfaces.end()) return found->second.get();
            const auto* info = source->info.bitmap;
            if (!info || info->bmiHeader.biBitCount != 32 || info->bmiHeader.biCompression != BI_RGB)
                throw std::runtime_error("Only 32-bit BI_RGB surfaces are supported");
            const int w = info->bmiHeader.biWidth, h = info->bmiHeader.biHeight;
            if (w <= 0 || h <= 0 || w > 16384 || h > 16384)
                throw std::runtime_error("Unsupported surface dimensions/orientation");
            const size_t bytes = size_t(w) * size_t(h) * 4;
            if (bytes > max_pixel_bytes - pixel_bytes)
                throw SnapshotCapacity();
            auto shared=context.cache.copy(source,source_tree,context.cache_enabled);
            auto* result=shared.get();
            surfaces.emplace(source,std::move(shared));
            pixel_bytes += bytes;
            return result;
        }

        Sprite* Snapshot::copy_node(const CaptureContext& context,const Sprite* source,Sprite* ancestor,unsigned depth) {
            if (!source || depth > 64 || nodes.size() >= max_nodes || !visited.insert(source).second)
                throw std::runtime_error("Invalid, cyclic or oversized render tree");
            const auto vt = reinterpret_cast<uintptr_t>(source->vftable) - reinterpret_cast<uintptr_t>(context.module);
            size_t bytes;
            int source_width=0,source_height=0;
            switch (vt) {
            case 0x22f24c:
                if (depth || source != context.screen)
                    throw std::runtime_error("Screen is only supported as the frame root");
                // Only slots 9 (clear background) and 10 (no-op) are used.
                // Never call the engine destructor or presentation methods.
                bytes = sizeof(Screen);
                break;
            case 0x1a9220:
                bytes = sizeof(RxViewport);
                if (viewport_has_custom_effect(source) &&
                    !viewport_snapshot_source_size(source,source_width,source_height))
                    throw LiveViewportEffect();
                break;
            case 0x1a8b78:
                bytes = sizeof(RxSprite);
                if (static_cast<const RxSprite*>(source)->angle != 0.0 && at_address<DWORD>(const_cast<Sprite*>(source),0x150)) {
                    // Native rotation preparation reads the live viewport registry.
                    // Execute it on the owner only, before copying the sprite.
                    if (!context.rotation_scratch) {
                        context.rotation_scratch=make_surface(1,1);
                    }
                    using Render = int (__thiscall*)(Sprite*,Surface*,RECT*);
                    auto render=reinterpret_cast<Render*>(source->vftable)[9];
                    RECT clip{0,0,1,1};
                    render(const_cast<Sprite*>(source),context.rotation_scratch.get(),&clip);
                }
                break;
            case 0x22f3cc: bytes = sizeof(SurfaceSprite); break;
            case 0x1a91ec: bytes = sizeof(TileSpriteSnapshot); break;
            case 0x1a8b40: bytes = sizeof(RxPlane); break;
            default:
                throw std::runtime_error("Unsupported node vtable RVA " + std::to_string(vt));
            }
            auto owned = std::make_unique<Node>();
            auto* node = owned.get();
            node->memory.add(bytes+sizeof(Node));
            node->data = std::make_unique<unsigned char[]>(bytes);
            std::memcpy(node->data.get(), source, vt == 0x1a91ec ? sizeof(RxTilemapSprite) : bytes);
            nodes.push_back(std::move(owned));
            node_bytes += bytes;
            auto* copy = node->get();
            copy->ancestor = ancestor;
            std::array<unsigned char,0x38> scale_attrs{};
            if (source_width>0 && viewport_snapshot_source_size(source,source_width,source_height,scale_attrs.data())) {
                const int64_t w=int64_t(copy->rect.left)+source_width;
                const int64_t h=int64_t(copy->rect.top)+source_height;
                if (copy->rect.left<0 || copy->rect.top<0 || w<=0 || h<=0 ||
                    w>16384 || h>16384)
                    throw std::runtime_error("Unsupported scaled viewport bounds");
                if (w*h>int64_t((max_pixel_bytes-pixel_bytes)/4))
                    throw SnapshotCapacity();
                pixel_bytes+=size_t(w*h)*4;
                auto target=make_surface(int(w),int(h));
                viewport_scales.emplace(copy,ViewportScale{source_width,source_height,std::move(target),scale_attrs});
            }

            const uintptr_t begin = reinterpret_cast<uintptr_t>(source->child_begin);
            const uintptr_t end = reinterpret_cast<uintptr_t>(source->child_end);
            if (end < begin || (end - begin) % sizeof(Sprite*) ||
                (end - begin) / sizeof(Sprite*) > max_nodes || (!begin && end))
                throw std::runtime_error("Invalid child range");
            const size_t count = (end - begin) / sizeof(Sprite*);
            node->memory.add((count+1)*sizeof(Sprite*));
            // Keep a real address even for an empty range (engine iterator checks).
            node->children.resize(count + 1, nullptr);
            for (size_t i = 0; i < count; ++i)
                node->children[i] = copy_node(context,source->child_begin[i], copy, depth + 1);
            copy->child_begin = node->children.data();
            copy->child_end = copy->child_begin + count;
            // RGSS's old checked vector occupies +78..8F: proxy at +78,
            // begin/end/capacity at +84/+88/+8C. The public Sprite declaration
            // stops before capacity; +8C is gap8C[0] in both supported subclasses.
            node->container = node->data.get() + 0x78;
            at_address<void*>(copy, 0x78) = &node->container;
            at_address<DWORD>(copy, 0x7c) = 0;
            at_address<DWORD>(copy, 0x80) = 0;
            at_address<Sprite**>(copy, 0x8c) = copy->child_end;
            if (vt != 0x1a9220 && vt != 0x22f24c) {
                auto* leaf = static_cast<SurfaceSprite*>(copy);
                leaf->surface90 = copy_surface(context,leaf->surface90);
                if (vt == 0x1a8b40) {
                    auto* plane=static_cast<RxPlane*>(copy);
                    const auto rect=at_address<RECT>(plane,0x100);
                    const double w=(rect.right-rect.left)*plane->doubleD8;
                    const double h=(rect.bottom-rect.top)*plane->doubleE0;
                    if (!std::isfinite(w) || !std::isfinite(h) || w<0 || h<0 || w>INT_MAX/2 || h>INT_MAX/2)
                        throw std::runtime_error("Unsupported Plane zoom/dimensions");
                    if (source->ancestor && reinterpret_cast<uintptr_t>(source->ancestor->vftable)-reinterpret_cast<uintptr_t>(context.module)==0x1a9220) {
                        // Native viewport getters 0x179a0 / 0x179c0, sampled on owner thread.
                        at_address<DWORD>(plane,0xcc) += at_address<DWORD>(source->ancestor,0xa8);
                        at_address<DWORD>(plane,0xd0) += at_address<DWORD>(source->ancestor,0xac);
                    }
                    plane->vftable=reinterpret_cast<SpriteVFTable*>(plane_vtable.data());
                }
                // +AC is part of the draw attributes, not the source bitmap;
                // it is not an owning pointer despite the old RMClasses name.
                if (vt == 0x1a8b78) {
                    auto* cache=at_address<Surface*>(copy,0x14c);
                    if (static_cast<RxSprite*>(copy)->angle!=0.0 && cache) {
                        // Native rotation writes bypass Bitmap notifications. Never
                        // reuse a cached version from a previous capture.
                        if (GetCurrentThreadId()==context.owner_thread) context.cache.invalidate(cache);
                        at_address<Surface*>(copy,0x14c)=copy_surface(context,cache);
                    } else at_address<Surface*>(copy,0x14c)=nullptr;
                    // The worker must never regenerate the cache via live registry.
                    at_address<DWORD>(copy,0x150)=0;
                }
                if (vt == 0x1a91ec) {
                    auto* tile = static_cast<TileSpriteSnapshot*>(copy);
                    const auto* live = static_cast<const RxTilemapSprite*>(source);
                    tile->tilemap = copy_tilemap(context,live->tilemap);
                    tile->columns = 21; tile->rows = 16;
                    if (context.hrfix) {
                        tile->columns = (tile->rect.right-tile->rect.left)/32+1;
                        tile->rows = (tile->rect.bottom-tile->rect.top)/32+1;
                        if (!is_cut_disabled_map(live->tilemap)) {
                            tile->columns = (std::min)(tile->columns, int(tile->tilemap->width));
                            tile->rows = (std::min)(tile->rows, int(tile->tilemap->height));
                        }
                    }
                    if (tile->columns < 0 || tile->rows < 0 || tile->columns > 127 || tile->rows > 127)
                        throw std::runtime_error("Unsupported Tilemap render bounds");
                    tile->vftable = reinterpret_cast<SpriteVFTable*>(tile_vtable.data());
                }
            }
            return copy;
        }
}
