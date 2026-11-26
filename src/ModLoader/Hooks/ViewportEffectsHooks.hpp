#pragma once

namespace rm_modloader {
    struct Sprite;
    // Used by the parallel renderer to reject state stored outside the tree.
    bool viewport_has_custom_effect(const Sprite* node);
    bool viewport_snapshot_source_size(const Sprite* node, int& width, int& height, void* attributes=nullptr);
    // Native geometric effects (zoom / angle / wave) for a whole Viewport, reusing the
    // engine's own RxSprite render kernel instead of Zeus Map Effects' Ruby snapshot
    // (Graphics.snap_to_bitmap full-framebuffer readback + per-frame Bitmap alloc).
    //
    // Enabled by "viewport_effects" or required by HRFix's original map size.
    // The menu bitmap blur API is always registered; it shares the effects pool
    // when present and otherwise runs the independent pixel kernel inline.
    // Viewport#source_size(w,h) captures logical source coordinates and scales
    // that layer to the viewport rect; source_size(0,0) restores normal sizing.
    void apply_viewport_effects();
}
