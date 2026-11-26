#pragma once
#include <chrono>
namespace rm_modloader {
    void reset_map_frame_probe();
    void apply_map_frame_probe();
    enum class MapProbePart { tilemap, viewport, viewport_subtree, count };
    bool map_frame_probe_recording();
    bool map_frame_probe_capture_enabled();
    void map_frame_probe_rendered(double ms);
    void map_frame_probe_add(MapProbePart part, double ms);
    void map_frame_probe_viewport_kind(bool custom);
    void map_frame_trace_dispatch(double ms, unsigned calls);
    bool map_frame_trace_recording();
    void map_frame_trace_dispatch_part(double original_ms, double peek_ms);
    void map_frame_trace_wndproc(double ms, unsigned message);
    class MapProbeScope {
        bool enabled;
        MapProbePart part;
        std::chrono::steady_clock::time_point begin;
    public:
        explicit MapProbeScope(MapProbePart p) : enabled(map_frame_probe_recording()), part(p) {
            if (enabled) begin = std::chrono::steady_clock::now();
        }
        ~MapProbeScope() {
            if (enabled) map_frame_probe_add(part, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-begin).count());
        }
        MapProbeScope(const MapProbeScope&) = delete;
        MapProbeScope& operator=(const MapProbeScope&) = delete;
    };
}
