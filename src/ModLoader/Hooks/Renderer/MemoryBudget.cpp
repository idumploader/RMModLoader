#include "MemoryBudget.hpp"
namespace rm_modloader::renderer {
unsigned pixel_limit_mib = default_pixel_limit_mib;
size_t max_pixel_bytes = size_t(default_pixel_limit_mib)*1024*1024;
std::atomic<size_t> renderer_bytes=0, renderer_peak_bytes=0;
SnapshotCapacity::SnapshotCapacity() : std::runtime_error("Renderer exceeds " +
    std::to_string(pixel_limit_mib) + " MiB memory limit") {}
void reserve_memory(size_t bytes) {
    size_t used=renderer_bytes.load();
    do {
        if (used>max_pixel_bytes || bytes>max_pixel_bytes-used) throw SnapshotCapacity();
    } while (!renderer_bytes.compare_exchange_weak(used,used+bytes));
    auto peak=renderer_peak_bytes.load();
    while (peak<used+bytes && !renderer_peak_bytes.compare_exchange_weak(peak,used+bytes)) {}
}
MemoryCharge::~MemoryCharge() { renderer_bytes.fetch_sub(bytes); }
void MemoryCharge::add(size_t amount) { reserve_memory(amount); bytes+=amount; }
void MemoryCharge::clear() { renderer_bytes.fetch_sub(bytes); bytes=0; }
}
