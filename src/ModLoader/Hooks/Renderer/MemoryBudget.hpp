#pragma once
#include <atomic>
#include <cstddef>
#include <stdexcept>
#include <string>

namespace rm_modloader::renderer {
inline constexpr unsigned default_pixel_limit_mib = 256;
extern unsigned pixel_limit_mib;
extern size_t max_pixel_bytes;
extern std::atomic<size_t> renderer_bytes, renderer_peak_bytes;
struct SnapshotCapacity : std::runtime_error {
    SnapshotCapacity();
};
void reserve_memory(size_t bytes);
// Charges renderer-owned payloads; allocator/container overhead is additional.
// Not movable: lifetime ownership must stay with the allocation it accounts for.
struct MemoryCharge {
    size_t bytes=0;
    MemoryCharge()=default;
    MemoryCharge(const MemoryCharge&)=delete;
    ~MemoryCharge();
    void add(size_t amount);
    void clear();
};
}
