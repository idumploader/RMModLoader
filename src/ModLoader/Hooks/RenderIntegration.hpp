#pragma once

namespace rm_modloader {
    // Essential RGSS render/presentation hooks, independent of trace recording.
    void apply_render_integration();
    void reset_render_integration();
}
