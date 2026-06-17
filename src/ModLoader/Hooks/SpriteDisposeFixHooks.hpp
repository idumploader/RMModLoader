#pragma once

namespace rm_modloader {

    /**
     * Guards against the viewport/sprite double-dispose use-after-free.
     *
     * This RGSS reimplementation (CNx / CRx classes) cascade-disposes every child
     * drawable when a viewport is disposed: Viewport#dispose frees the C++ objects
     * of all sprites/planes attached to that viewport. The freed objects' *Ruby*
     * wrappers are left untouched, still holding a dangling native pointer.
     *
     * A lot of (third-party) scripts dispose a shared viewport before calling
     * `super` / disposing the children themselves, e.g.:
     *
     *     def dispose
     *       self.viewport.dispose   # cascade-frees self's C++ object
     *       super                   # disposes self again -> double free
     *     end
     *
     * The second disposal re-runs the scalar deleting destructor on freed memory:
     *   - it unlinks from the (also freed) ancestor's draw list -> std::find on
     *     freed memory -> 0xC0000005 crash at battle start;
     *   - it runs the vector destructor + operator delete a second time -> heap
     *     corruption (observed as passability/collision glitches after battle).
     *
     * apply_sprite_dispose_fix() keeps a registry of live drawable C++ objects and
     * makes destruction idempotent, so any duplicate dispose is dropped safely
     * regardless of the order scripts use.
     */
    void apply_sprite_dispose_fix();
}
