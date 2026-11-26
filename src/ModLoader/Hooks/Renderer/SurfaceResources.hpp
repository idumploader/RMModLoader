#pragma once
#include "../../RMClasses.hpp"
#include <memory>
#include <unordered_map>
#include <cstdint>

namespace rm_modloader::renderer {
// RGSS301 functions are bound once before hooks run. Accessors do not consult
// live game objects: a worker may use them on its independently owned surfaces.
void initialize_surface_resources(bool hrfix);
bool surface_resources_ready();
unsigned char* pixels(Surface* surface);
int stride(Surface* surface);
void render_walk(Sprite* root,Surface* destination,DWORD* origin,int* offset,RECT* clip);
struct SurfaceDeleter {
    size_t bytes=0;
    void operator()(Surface* surface) const;
};
using OwnedSurface = std::unique_ptr<Surface,SurfaceDeleter>;
using SharedSurface = std::shared_ptr<Surface>;
OwnedSurface make_surface(int width,int height);

// Only the game thread may mutate the cache. Captured trees retain old versions
// by shared ownership; invalidation never changes a surface read by the worker.
class SurfaceCache {
public:
    struct Statistics {
        size_t bytes=0;
        uint64_t copied_bytes=0, hits=0, misses=0;
    };
    SharedSurface copy(Surface* source,bool source_tree,bool enabled);
    void invalidate(Surface* source);
    void clear();
    void reset_counters();
    const Statistics& statistics() const { return statistics_; }
private:
    struct Entry { SharedSurface surface; size_t bytes; };
    std::unordered_map<Surface*,Entry> entries_;
    Statistics statistics_;
};
}
