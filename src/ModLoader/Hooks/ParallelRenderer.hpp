#pragma once
#include "../RMClasses.hpp"
#include <cstdint>
#include <memory>

namespace rm_modloader {
    struct RenderFrameCounters {
        int mode;
        uint64_t collects, skipped, repeats, fallbacks, present_intervals;
        double present_ms, submit_ms, copy_ms, wait_ms, worker_ms;
    };
    RenderFrameCounters render_frame_counters();
    // Snapshot ownership and worker backend; Display keeps it off by default.
    void apply_parallel_renderer();
    void remember_screen_frame(Screen*, Surface*, int, int, RECT*, bool);
    void begin_last_frame_presentation();
    void end_last_frame_presentation(int);
    void preserve_last_frame_before_render();
    // Called on the game thread, outside DllMain, before leaving rgss_main.
    void finish_parallel_renderer();
    // Recursive walker hooks must use only captured state while replaying.
    // Native tone and isolated logical-source scaling are supported.
    bool parallel_renderer_drawing();
    bool render_snapshot_viewport_scale(const Sprite*, int&, int&, Surface*&, const void*&);
    // Full-frame renderer, called only inside Graphics.update.
    bool render_snapshot_frame(Screen*, Surface*, int, int, RECT*);
    void begin_snapshot_presentation();
    void end_snapshot_presentation(HDC target, int left, int top, int result);
    void begin_direct_frame_output();
    Surface* direct_frame_output_surface();
    void end_direct_frame_output();
    void validate_direct_frame_output(HDC,int,int,int);
    std::shared_ptr<Surface> retain_completed_frame_surface(Surface*);
}
