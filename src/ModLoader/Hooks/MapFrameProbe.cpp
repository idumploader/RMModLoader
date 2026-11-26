#define NOMINMAX
#include "MapFrameProbe.hpp"
#include "ParallelRenderer.hpp"
#include "SteamOverlayHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"
#include "../RMGlobal.hpp"
#include <array>
#include <algorithm>
#include <chrono>

namespace rm_modloader {
namespace {
    using Clock = std::chrono::steady_clock;
    thread_local bool active = false;
    thread_local bool frame_trace_active = false;
    DWORD owner = 0;
    double graphics_ms = 0, render_ms = 0, scheduler_ms = 0;
    uint64_t updates = 0, renders = 0, rendered_updates = 0;
    double parts_ms[static_cast<int>(MapProbePart::count)]{};
    uint64_t parts_calls[static_cast<int>(MapProbePart::count)]{};
    uint64_t custom_viewports = 0, scaling_viewports = 0;
    struct FrameTraceRow {
        double clock_ms, interval_ms, graphics_ms, render_ms, scheduler_ms;
        uint64_t renders, collects, skipped, repeats, fallbacks, present_intervals;
        double present_ms, submit_ms, copy_ms, wait_ms, worker_ms;
        uint64_t overlay_frames;
        double overlay_ms;
        int mode;
        double dispatch_ms;
        unsigned dispatch_calls;
        double dispatch_original_max_ms, dispatch_peek_max_ms, wndproc_max_ms;
        unsigned wndproc_message, wndproc_calls;
    };
    constexpr size_t frame_trace_capacity = 18000;
    std::array<FrameTraceRow, frame_trace_capacity> frame_trace_rows{};
    size_t frame_trace_count = 0, frame_trace_head = 0;
    uint64_t frame_trace_dropped = 0;
    Clock::time_point frame_trace_begin{}, frame_trace_last_end{};
    double frame_trace_dispatch_ms = 0;
    unsigned frame_trace_dispatch_calls = 0;
    double frame_trace_dispatch_original_max_ms = 0;
    double frame_trace_dispatch_peek_max_ms = 0;
    double frame_trace_wndproc_max_ms = 0;
    unsigned frame_trace_wndproc_message = 0;
    unsigned frame_trace_wndproc_calls = 0;
    double elapsed(Clock::time_point begin) {
        return std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
    }
    bool recording() { return active && GetCurrentThreadId() == owner; }
    bool capture_enabled() { return (active || frame_trace_active) && GetCurrentThreadId() == owner; }
    RubyValue (__cdecl* original_update)(RubyValue);
    RubyValue __cdecl update_hook(RubyValue self) {
        if (!capture_enabled()) return original_update(self);
        const auto begin = Clock::now();
        frame_trace_dispatch_ms=0;
        frame_trace_dispatch_calls=0;
        frame_trace_dispatch_original_max_ms=0;
        frame_trace_dispatch_peek_max_ms=0;
        frame_trace_wndproc_max_ms=0;
        frame_trace_wndproc_message=0;
        frame_trace_wndproc_calls=0;
        const auto renders_before = renders;
        const auto render_before = render_ms, scheduler_before = scheduler_ms;
        const bool tracing = frame_trace_active;
        const auto counters_before = tracing ? render_frame_counters() : RenderFrameCounters{};
        const auto overlay_frames_before = tracing ? steam_overlay_frame_count() : 0;
        const auto overlay_ms_before = tracing ? steam_overlay_render_ms() : 0.0;
        auto result = original_update(self);
        const auto end = Clock::now();
        const double graphics_duration = std::chrono::duration<double, std::milli>(end-begin).count();
        graphics_ms += graphics_duration;
        ++updates;
        if (renders != renders_before) ++rendered_updates;
        if (tracing) {
            const auto after = render_frame_counters();
            FrameTraceRow row{
                std::chrono::duration<double, std::milli>(end-frame_trace_begin).count(),
                frame_trace_last_end == Clock::time_point{} ? -1.0 :
                    std::chrono::duration<double, std::milli>(end-frame_trace_last_end).count(),
                graphics_duration, render_ms-render_before, scheduler_ms-scheduler_before,
                renders-renders_before, after.collects-counters_before.collects,
                after.skipped-counters_before.skipped, after.repeats-counters_before.repeats,
                after.fallbacks-counters_before.fallbacks,
                after.present_intervals-counters_before.present_intervals,
                after.present_ms-counters_before.present_ms,
                after.submit_ms-counters_before.submit_ms,
                after.copy_ms-counters_before.copy_ms,
                after.wait_ms-counters_before.wait_ms,
                after.worker_ms-counters_before.worker_ms,
                steam_overlay_frame_count()-overlay_frames_before,
                steam_overlay_render_ms()-overlay_ms_before, after.mode,
                frame_trace_dispatch_ms, frame_trace_dispatch_calls,
                frame_trace_dispatch_original_max_ms, frame_trace_dispatch_peek_max_ms,
                frame_trace_wndproc_max_ms, frame_trace_wndproc_message,
                frame_trace_wndproc_calls};
            frame_trace_rows[(frame_trace_head+frame_trace_count)%frame_trace_capacity] = row;
            if (frame_trace_count < frame_trace_capacity) ++frame_trace_count;
            else { frame_trace_head=(frame_trace_head+1)%frame_trace_capacity; ++frame_trace_dropped; }
            frame_trace_last_end=end;
        }
        return result;
    }
    struct FrameProbe : GameFrame {
        static int (__thiscall GameFrame::* original_schedule)();
        int __thiscall schedule_hook() {
            if (!capture_enabled()) return (this->*original_schedule)();
            const auto begin = Clock::now();
            const auto result = (this->*original_schedule)();
            scheduler_ms += elapsed(begin);
            return result;
        }
    };
    int (__thiscall GameFrame::* FrameProbe::original_schedule)() = nullptr;
    RubyValue __cdecl start(RubyValue) {
        owner = GetCurrentThreadId();
        graphics_ms = render_ms = scheduler_ms = 0;
        updates = renders = rendered_updates = 0;
        for (auto& value : parts_ms) value = 0;
        for (auto& value : parts_calls) value = 0;
        custom_viewports = scaling_viewports = 0;
        active = true;
        return ruby_true;
    }
    RubyValue __cdecl stop(RubyValue) {
        active = false;
        const std::string report = nlohmann::json{
            {"graphics_ms", graphics_ms}, {"render_ms", render_ms},
            {"scheduler_ms", scheduler_ms}, {"updates", updates}, {"renders", renders},
            {"rendered_updates", rendered_updates},
            {"tilemap_ms", parts_ms[0]}, {"tilemap_calls", parts_calls[0]},
            {"viewport_total_ms", parts_ms[1]}, {"viewport_subtree_ms", parts_ms[2]},
            {"viewport_overhead_ms", parts_ms[1] - parts_ms[2]},
            {"custom_viewports", custom_viewports}, {"scaling_viewports", scaling_viewports},
            {"graphics_other_ms", graphics_ms - render_ms - scheduler_ms}
        }.dump();
        return rb_str_new(report.data(), static_cast<long>(report.size()));
    }
    RubyValue __cdecl frame_trace_start(RubyValue) {
        owner = GetCurrentThreadId();
        frame_trace_count=frame_trace_head=0;
        frame_trace_dropped=0;
        frame_trace_begin=Clock::now();
        frame_trace_last_end={};
        frame_trace_active=true;
        return ruby_true;
    }
    RubyValue __cdecl frame_trace_status(RubyValue) {
        const std::string report=nlohmann::json{
            {"active",frame_trace_active},{"count",frame_trace_count},
            {"dropped",frame_trace_dropped},{"capacity",frame_trace_capacity}}
            .dump();
        return rb_str_new(report.data(),static_cast<long>(report.size()));
    }
    RubyValue __cdecl frame_trace_stop(RubyValue) {
        frame_trace_active=false;
        nlohmann::json rows=nlohmann::json::array();
        for (size_t i=0; i<frame_trace_count; ++i) {
            const auto& r=frame_trace_rows[(frame_trace_head+i)%frame_trace_capacity];
            rows.push_back({r.clock_ms,r.interval_ms,r.graphics_ms,r.render_ms,r.scheduler_ms,
                r.renders,r.collects,r.skipped,r.repeats,r.fallbacks,r.present_intervals,
                r.present_ms,r.submit_ms,r.copy_ms,r.wait_ms,r.worker_ms,
                r.overlay_frames,r.overlay_ms,r.mode,r.dispatch_ms,r.dispatch_calls,
                r.dispatch_original_max_ms,r.dispatch_peek_max_ms,r.wndproc_max_ms,
                r.wndproc_message,r.wndproc_calls});
        }
        const std::string report=nlohmann::json{
            {"count",frame_trace_count},{"dropped",frame_trace_dropped},
            {"columns",{"clock_ms","interval_ms","graphics_ms","render_ms",
                "scheduler_ms","renders","collects","skipped","repeats","fallbacks",
                "present_intervals","present_ms","submit_ms","copy_ms","wait_ms",
                "worker_ms","overlay_frames","overlay_ms","mode",
                "dispatch_ms","dispatch_calls","dispatch_original_max_ms",
                "dispatch_peek_max_ms","wndproc_max_ms","wndproc_message",
                "wndproc_calls"}},
            {"rows",std::move(rows)}}.dump();
        return rb_str_new(report.data(),static_cast<long>(report.size()));
    }
}
bool map_frame_probe_recording() { return recording(); }
bool map_frame_probe_capture_enabled() { return capture_enabled(); }
void map_frame_probe_rendered(double ms) { render_ms += ms; ++renders; }
bool map_frame_trace_recording() { return frame_trace_active && GetCurrentThreadId()==owner; }
void map_frame_trace_dispatch(double ms, unsigned calls) {
    if (map_frame_trace_recording()) {
        frame_trace_dispatch_ms+=ms;
        frame_trace_dispatch_calls+=calls;
    }
}
void map_frame_trace_dispatch_part(double original_ms, double peek_ms) {
    if (!map_frame_trace_recording()) return;
    frame_trace_dispatch_original_max_ms=std::max(frame_trace_dispatch_original_max_ms,original_ms);
    frame_trace_dispatch_peek_max_ms=std::max(frame_trace_dispatch_peek_max_ms,peek_ms);
}
void map_frame_trace_wndproc(double ms, unsigned message) {
    if (!map_frame_trace_recording()) return;
    ++frame_trace_wndproc_calls;
    if (ms>frame_trace_wndproc_max_ms) {
        frame_trace_wndproc_max_ms=ms;
        frame_trace_wndproc_message=message;
    }
}
void reset_map_frame_probe() { active=false; frame_trace_active=false; }
void map_frame_probe_add(MapProbePart part, double ms) {
    const auto index = static_cast<int>(part);
    parts_ms[index] += ms;
    ++parts_calls[index];
}
void map_frame_probe_viewport_kind(bool custom) {
    if (!recording()) return;
    if (custom) ++custom_viewports; else ++scaling_viewports;
}
void apply_map_frame_probe() {
    // RGSS301 IDA: Graphics.update = update_game_frame + F12 + scheduler.
    // 0x2590 includes message dispatch and FPS waiting, not only sleep.
    mod_loader->hook_function(0xb080, &update_hook, &original_update);
    mod_loader->hook_method(0x2590, &FrameProbe::schedule_hook, &FrameProbe::original_schedule);
    mod_loader->add_preinit_handler([] {
        active = false;
        mod_loader->register_ruby_method("map_frame_probe_start", start);
        mod_loader->register_ruby_method("map_frame_probe_stop", stop);
        mod_loader->register_ruby_method("map_frame_trace_start", frame_trace_start);
        mod_loader->register_ruby_method("map_frame_trace_status", frame_trace_status);
        mod_loader->register_ruby_method("map_frame_trace_stop", frame_trace_stop);
    });
}
}
