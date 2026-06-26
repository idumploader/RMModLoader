#pragma once

namespace rm_modloader {
    // Native geometric effects (zoom / angle / wave) for a whole Viewport, reusing the
    // engine's own RxSprite render kernel instead of Zeus Map Effects' Ruby snapshot
    // (Graphics.snap_to_bitmap full-framebuffer readback + per-frame Bitmap alloc).
    //
    // Gated behind the "viewport_effects" config key (default off) — this is a
    // work-in-progress seam, not yet a user-facing effect. See RMClasses.hpp / task #40.
    void apply_viewport_effects();
}
