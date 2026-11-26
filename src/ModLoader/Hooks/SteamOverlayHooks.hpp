#pragma once
#include <cstdint>
#include "../RMClasses.hpp"

namespace rm_modloader {
    struct Screen;
    uint64_t steam_overlay_frame_count();
    double steam_overlay_render_ms();
    bool steam_overlay_ready();
    uint64_t steam_overlay_capture_bytes();
    uint64_t steam_overlay_missing_frames();
    double steam_overlay_capture_ms();
    int steam_overlay_optimizations();
    void configure_steam_overlay_optimizations(int);
    uint64_t steam_overlay_borrowed_frames();
    uint64_t steam_overlay_materialized_frames();
    uint64_t steam_overlay_parallel_operations();
    int steam_overlay_capture_pitch();
    void capture_steam_overlay_surface(Screen*,Surface*,int,int,RECT*);
    void reset_steam_overlay_frame();

	extern void apply_steam_overlay_hooks();
}
