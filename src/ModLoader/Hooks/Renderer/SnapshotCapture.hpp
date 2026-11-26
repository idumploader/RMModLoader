#pragma once
#include "MemoryBudget.hpp"
#include "SurfaceResources.hpp"
#include <array>
#include <unordered_set>
#include <vector>

namespace rm_modloader::renderer {
inline constexpr size_t max_nodes=8192;
struct LiveViewportEffect : std::runtime_error {
    LiveViewportEffect() : std::runtime_error("Custom ViewportEffects require live rendering") {}
};
// A game-thread capture capability. Never retained by Snapshot or WorkerJob.
struct CaptureContext {
    SurfaceCache& cache;
    bool cache_enabled;
    OwnedSurface& rotation_scratch;
    bool hrfix;
    DWORD owner_thread;
    HMODULE module;
    Screen* screen;
};
    // Never call an engine Sprite destructor on these byte copies: they were
    // not registered with the engine and do not own engine drawlist allocations.
    struct Node {
        MemoryCharge memory;
        std::unique_ptr<unsigned char[]> data;
        std::vector<Sprite*> children;
        void* container = nullptr; // engine checked-iterator proxy -> copied vector
        Sprite* get() const { return reinterpret_cast<Sprite*>(data.get()); }
    };

    struct Snapshot {
        struct ViewportScale {
            int width=0,height=0;
            OwnedSurface target;
            std::array<unsigned char,0x38> attributes{};
        };
        std::unordered_map<const Sprite*,ViewportScale> viewport_scales;
        struct TileState {
            MemoryCharge memory;
            RxTilemap value{};
            std::vector<int16_t> map, flags, flash;
        };
        std::unordered_map<const RxTilemap*, std::unique_ptr<TileState>> tilemaps;
        std::vector<std::unique_ptr<Node>> nodes;
        std::unordered_map<Surface*, SharedSurface> surfaces;
        bool source_tree;
        explicit Snapshot(bool sources = false) : source_tree(sources) {}
        std::unordered_set<const Sprite*> visited;
        Sprite parent{}; // non-null ancestor marker for a detached viewport root
        size_t pixel_bytes = 0;
        size_t node_bytes = 0;
        size_t table_bytes = 0;

        RxTilemap* copy_tilemap(const CaptureContext&,const RxTilemap* source);
        Surface* copy_surface(const CaptureContext&,Surface* source);
        Sprite* copy_node(const CaptureContext&,const Sprite* source,Sprite* ancestor,unsigned depth=0);
    };
}
