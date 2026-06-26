#include "ViewportEffectsHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMClasses.hpp"
#include "../RMGlobal.hpp"

#include <mutex>
#include <cstring>
#include <unordered_map>

namespace rm_modloader {

    // Native viewport ZOOM, reusing the engine's scene walker + stretch-blit (no RGSS sprite
    // object is created -- a plain SurfaceSprite has no zoom/wave fields anyway; zoom is just a
    // stretched M_draw_on_surface). The effect can be attached to ANY Viewport from Ruby
    // (Viewport#zoom=), keyed by the viewport's globally-unique creation id; a global default
    // (config / ModLoader.viewport_*) still drives the auto-detected map viewport.
    //
    // RGSS301 base 0x10000000 (offsets = IDA addr - base):
    //   0x110820  scene walker sub_10110820(this=node, dest, POINT* origin, int* off, RECT* clip).
    //             Recurses a node's drawlist with full per-node coord setup. Root = render-to-screen.
    //   0x10BB00  M_draw_on_surface(dest, destRect, src, srcRect, attrs) -- stretches src->dest.
    //   0x10C450  fill_rect(surface, RECT*, color)
    //   0x10B120  Surface_ctx(surface, bitcount=32)
    //   0x10B3B0  M_init_surface_bitmap(surface, w, h)  (CreateDIBSection)
    //   0x10B280  Surface_dtx(surface, char flags) -- scalar deleting dtor; flags&1 -> operator delete.
    //   0x17E979  operator new(size_t)
    //   0x034DD0  rb_num2dbl(RubyValue) -- RGSS NUM2DBL: Float->[+8], coerces Int via rb_Float.
    //   0x05A250  rb_float_new(double) -- newobj T_FLOAT, double at [+8]. For the zoom getter.
    //   0x1A9220  &CRxViewport::vftable
    //   leaf vftables (attrs donor): RxSprite 0x1A8B78, SurfaceSprite 0x22F3CC,
    //             RxPlane 0x1A8B40, RxTilemapSprite 0x1A91EC. A SurfaceSprite's 0x38-byte
    //             attribute block lives at object+0x94 (M_copy_surface_sprite_attributes).
    //   Sprite+0x70 = sprite_id: a globally-unique, monotonically-increasing creation id (the
    //             base ctor stores gM_sprite_count++ there). Used as the per-viewport map key --
    //             never repeats, so a freed+reused viewport address can't inherit a stale effect.
    namespace {
        constexpr ptrdiff_t walker_offset              = 0x110820;
        constexpr ptrdiff_t draw_on_surface_offset     = 0x10BB00;
        constexpr ptrdiff_t fill_rect_offset           = 0x10C450;
        constexpr ptrdiff_t surface_ctor_offset        = 0x10B120;
        constexpr ptrdiff_t surface_init_bitmap_offset = 0x10B3B0;
        constexpr ptrdiff_t surface_dtor_offset        = 0x10B280;
        constexpr ptrdiff_t op_new_offset              = 0x17E979;
        constexpr ptrdiff_t num2dbl_offset             = 0x034DD0;   // rb_num2dbl (RGSS NUM2DBL)
        constexpr ptrdiff_t float_new_offset           = 0x05A250;   // rb_float_new(double)
        constexpr ptrdiff_t rxviewport_vtable_offset   = 0x1A9220;   // &CRxViewport::vftable
        constexpr ptrdiff_t leaf_vtable_offsets[4]     = { 0x1A8B78, 0x22F3CC, 0x1A8B40, 0x1A91EC };

        constexpr int   attrs_size = 0x38;      // SurfaceSpriteAttributes
        constexpr int   attrs_at   = 0x94;      // its offset inside a SurfaceSprite

        using op_new_t    = void* (__cdecl*)(unsigned int);
        using surf_ctor_t = Surface* (__thiscall*)(Surface*, int);
        using surf_init_t = int (__thiscall*)(Surface*, int, int);
        using surf_dtor_t = void* (__thiscall*)(Surface*, char);
        using fill_rect_t = int (__thiscall*)(Surface*, RECT*, DWORD);
        using draw_t      = int (__thiscall*)(Surface*, RECT*, Surface*, RECT*, void*);
        using num2dbl_t   = double (__cdecl*)(RubyValue);
        using float_new_t = RubyValue (__cdecl*)(double);

        op_new_t    e_op_new    = nullptr;
        surf_ctor_t e_surf_ctor = nullptr;
        surf_init_t e_surf_init = nullptr;
        surf_dtor_t e_surf_free = nullptr;
        fill_rect_t e_fill_rect = nullptr;
        draw_t      e_draw      = nullptr;
        num2dbl_t   e_num2dbl   = nullptr;
        float_new_t e_float_new = nullptr;
        const void* g_vp_vtable = nullptr;
        const void* g_leaf_vt[4] = { nullptr, nullptr, nullptr, nullptr };

        // One viewport's effect. center_* is the zoom focus in screen pixels (the captured
        // content lands at absolute coords in the backbuffer); inactive -> focus on the
        // viewport centre. zoom <= 1.0 means "no visible effect" (skipped by the walker).
        struct VPEffect {
            double zoom = 1.0;
            bool   center_active = false;
            int    center_x = 0, center_y = 0;
            bool   active() const { return zoom > 1.0; }
        };

        // Per-viewport effects, keyed by Sprite::sprite_id (unique forever). Touched only from
        // the game thread (Ruby setters and the render walk both run there in RGSS), so no lock.
        std::unordered_map<DWORD, VPEffect> g_effects;

        // Global default applied to the auto-detected map viewport (the one whose subtree holds
        // the tilemap). Seeded from config, live-tweakable via ModLoader.viewport_*. An explicit
        // per-viewport effect on that same viewport overrides this.
        bool   g_map_capture = false;
        double g_map_zoom    = 1.0;
        bool   g_map_center_active = false;
        int    g_map_center_x = 0, g_map_center_y = 0;

        Surface* g_backbuffer = nullptr;
        int      g_bb_w = 0, g_bb_h = 0;
        bool     g_in_capture = false;

        // The native C++ object pointer is STORED at DATA_PTR(self)+8 (the Ruby wrapper's
        // `native` field), so it must be dereferenced -- not treated as the object address.
        // (Mirrors HRFix's at_address<T*>(data, 8) and SpriteDisposeFix's wrapper.native.)
        template<typename T>
        inline T* rgss_native(RubyValue ruby_obj) {
            void* data = get_rb_data_data<void>(ruby_obj);
            return data ? *reinterpret_cast<T**>(reinterpret_cast<char*>(data) + 8) : nullptr;
        }

        inline bool is_viewport(const Sprite* n) {
            return *reinterpret_cast<const void* const*>(n) == g_vp_vtable;
        }
        // The map viewport is the one whose subtree contains the tilemap (RxTilemapSprite,
        // g_leaf_vt[3]). Child COUNT is a bad proxy: the 507-child viewport was the event/sprite
        // layer (mostly off-screen -> drew nothing -> empty capture).
        inline bool has_tilemap(const Sprite* n, int depth) {
            if (!n || depth > 3) return false;
            for (Sprite** it = n->child_begin; it && it < n->child_end; ++it) {
                if (*reinterpret_cast<void* const*>(*it) == g_leaf_vt[3]) return true;
                if (has_tilemap(*it, depth + 1)) return true;
            }
            return false;
        }
        inline bool is_leaf(const Sprite* n) {
            const void* vt = *reinterpret_cast<const void* const*>(n);
            for (const void* lv : g_leaf_vt) if (vt == lv) return true;
            return false;
        }

        // Decide whether this node gets a zoom this frame and with what params. Explicit
        // per-viewport effect wins; otherwise the global map default if this is the map viewport.
        inline bool resolve_effect(const Sprite* n, VPEffect& out) {
            if (!is_viewport(n)) return false;
            auto it = g_effects.find(n->sprite_id);
            if (it != g_effects.end() && it->second.active()) { out = it->second; return true; }
            if (g_map_capture && g_map_zoom > 1.0 && has_tilemap(n, 0)) {
                out.zoom = g_map_zoom;
                out.center_active = g_map_center_active;
                out.center_x = g_map_center_x;
                out.center_y = g_map_center_y;
                return true;
            }
            return false;
        }

        // Copy a valid 0x38 attribute block (blend + opacity etc.) from the first leaf
        // descendant. M_draw_on_surface takes the source pixels via its `src` arg, so the
        // donor's embedded surface is irrelevant -- we only want its blend/opacity.
        bool grab_attrs(Sprite* node, void* out, int depth) {
            if (!node || depth > 8) return false;
            if (is_leaf(node)) { std::memcpy(out, reinterpret_cast<char*>(node) + attrs_at, attrs_size); return true; }
            for (Sprite** it = node->child_begin; it && it < node->child_end; ++it)
                if (grab_attrs(*it, out, depth + 1)) return true;
            return false;
        }

        // Grow-only backbuffer: sized to the largest viewport seen, never shrinks, so two
        // viewports of different sizes don't thrash a realloc every frame. The old surface is
        // freed via Surface_dtx (dtor + operator delete) -- the previous version leaked it.
        bool ensure_backbuffer(int w, int h) {
            if (w <= 0 || h <= 0) return false;
            if (g_backbuffer && g_bb_w >= w && g_bb_h >= h) return true;
            int nw = g_bb_w > w ? g_bb_w : w;
            int nh = g_bb_h > h ? g_bb_h : h;
            void* mem = e_op_new(sizeof(Surface));
            if (!mem) return g_backbuffer != nullptr;     // keep the old one on alloc failure
            Surface* bb = e_surf_ctor(static_cast<Surface*>(mem), 32);
            if (!e_surf_init(bb, nw, nh)) return g_backbuffer != nullptr;
            Surface* old = g_backbuffer;
            g_backbuffer = bb; g_bb_w = nw; g_bb_h = nh;
            if (old && e_surf_free) e_surf_free(old, 1);
            mod_loader->log_info("ViewportEffects: backbuffer grown to {}x{}\n", nw, nh);
            return true;
        }
    }

    struct WalkerHook : Sprite {
        // sub_10110820 is __thiscall(this, Surface* dest, POINT* origin, int* off, RECT* clip):
        // 4 stack args (it ends in `retn 10h`). IDA's decompiler shows a spurious 5th (a6).
        static void* (__thiscall Sprite::* orig)(Surface*, DWORD*, int*, RECT*);

        void* __thiscall walk_hook(Surface* dest, DWORD* origin, int* off, RECT* clip) {
            VPEffect eff;
            if (g_in_capture || !resolve_effect(this, eff)) {
                return (this->*orig)(dest, origin, off, clip);
            }

            RECT vr = this->rect;
            int w = vr.right - vr.left, h = vr.bottom - vr.top;
            unsigned char attrs[attrs_size];
            if (!ensure_backbuffer(vr.right, vr.bottom) || !grab_attrs(this, attrs, 0)) {
                return (this->*orig)(dest, origin, off, clip);
            }

            // 1) composite the subtree into our backbuffer via the engine's own walker.
            // Reset the backbuffer's draw-offset/clip to full first: when capturing the whole
            // Screen its slot9 sets these up, but a mid-walk viewport node does not -- left
            // stale, the viewport's children clip to nothing (empty/black capture).
            RECT bbfull = { 0, 0, g_bb_w, g_bb_h };
            g_backbuffer->left_offset = 0;
            g_backbuffer->top_offset  = 0;
            g_backbuffer->rect = bbfull;
            e_fill_rect(g_backbuffer, &bbfull, 0);
            g_in_capture = true;
            (this->*orig)(g_backbuffer, origin, off, clip);
            g_in_capture = false;

            // Blend 0x10000: routes to the general custom_draw blitter (stretches) AND skips
            // its opacity==255 fast path -- which is an opaque copy that writes transparent
            // source pixels as black (that black-screen over the HUD). The non-fast path does
            // per-pixel alpha so the transparent parts of this map layer show the HUD beneath.
            // (Plain 0x80000000 -> dynamic_draw = 1:1 no stretch; blend 0 -> opaque, blacks.)
            *reinterpret_cast<DWORD*>(attrs) = 0x10000;

            // 2) zoom about the focus by SAMPLING a sub-rect of the backbuffer and stretching it
            // over the full viewport. (Enlarging the dest rect past the surface instead just gets
            // clamped -> the zoom is lost.) z>=1 zooms in; z<1 would need a sub-region larger than
            // the buffer, so we never store zoom<=1 as active.
            double z = eff.zoom;
            int sw = static_cast<int>(w / z), sh = static_cast<int>(h / z);
            // Centre the sampled sub-rect on the focus point (viewport centre by default, or a
            // script-set screen pixel for follow-cam). Clamp inside the viewport so we never
            // sample outside the captured layer (which would smear the edge / show 0s).
            int cx = eff.center_active ? eff.center_x : (vr.left + w / 2);
            int cy = eff.center_active ? eff.center_y : (vr.top + h / 2);
            int sx = cx - sw / 2, sy = cy - sh / 2;
            if (sx < vr.left) sx = vr.left;
            if (sy < vr.top)  sy = vr.top;
            if (sx + sw > vr.right)  sx = vr.right - sw;
            if (sy + sh > vr.bottom) sy = vr.bottom - sh;
            RECT src = { sx, sy, sx + sw, sy + sh };

            // The stretch clipper (sub_1010CC60) offsets+clips the dest rect by the dest
            // surface's draw-offset (left/top_offset) and clip rect -- which the walker sets
            // per-sprite and leaves in a stale, tiny state by the time we blit. Reset them so our
            // stretch isn't clipped away. Use the viewport's own bounds (not the grow-only
            // backbuffer size, which can exceed this viewport). Safe: we skip the normal render
            // this frame and the walker re-sets these next frame.
            dest->left_offset = 0;
            dest->top_offset  = 0;
            dest->rect.left   = 0;
            dest->rect.top    = 0;
            dest->rect.right  = vr.right;
            dest->rect.bottom = vr.bottom;
            e_draw(dest, &vr, g_backbuffer, &src, attrs);
            return this;
        }
    };

    void* (__thiscall Sprite::* WalkerHook::orig)(Surface*, DWORD*, int*, RECT*) = nullptr;

    // --- Ruby API -----------------------------------------------------------------------------
    // Per-viewport methods live on the Viewport class (Viewport#zoom= / #zoom / #zoom_center /
    // #zoom_auto_center). Global map-default helpers live on the ModLoader module
    // (ModLoader.viewport_*). Both only mutate the state the walker reads; the walker hook and
    // engine fns are only installed when "viewport_effects" is enabled in config.
    namespace {
        // RubyValue -> double via the engine's own NUM2DBL (rb_num2dbl): reads RFloat[+8] for a
        // Float and coerces an Integer through rb_Float, so `zoom = 2` and `zoom = 1.5` both work.
        // Manual fallback (Fixnum tag-shift / RFloat read) only if the function didn't resolve.
        double rb_value_to_double(RubyValue v) {
            if (e_num2dbl) return e_num2dbl(v);
            if (is_rb_fixnum(v)) return static_cast<double>(static_cast<int>(v) >> 1);
            if (rb_type(v) == RUBY_T_FLOAT)
                return *reinterpret_cast<double*>(reinterpret_cast<char*>(v) + sizeof(RubyRBasic));
            return static_cast<double>(rb_parse_int(v));
        }
        inline RubyValue rb_double_value(double d) {
            return e_float_new ? e_float_new(d) : rb_make_number(static_cast<long>(d));
        }
        inline bool rb_truthy(RubyValue v) { return v != ruby_nil && v != ruby_false; }

        // -- Viewport instance methods (self = a Ruby Viewport) --
        RubyValue __cdecl vp_set_zoom(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (!vp) return v;
            double z = rb_value_to_double(v);
            auto it = g_effects.find(vp->sprite_id);
            if (z > 1.0) {
                g_effects[vp->sprite_id].zoom = z;
            } else if (it != g_effects.end()) {
                // back to 1x: drop the entry unless a custom centre is still pinned to it.
                if (it->second.center_active) it->second.zoom = 1.0;
                else g_effects.erase(it);
            }
            return v;
        }
        RubyValue __cdecl vp_get_zoom(RubyValue self) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            double z = 1.0;
            if (vp) { auto it = g_effects.find(vp->sprite_id); if (it != g_effects.end()) z = it->second.zoom; }
            return rb_double_value(z);
        }
        RubyValue __cdecl vp_set_center(RubyValue self, RubyValue x, RubyValue y) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (!vp) return ruby_nil;
            VPEffect& e = g_effects[vp->sprite_id];
            e.center_active = true;
            e.center_x = rb_parse_int(x);
            e.center_y = rb_parse_int(y);
            return ruby_nil;
        }
        RubyValue __cdecl vp_auto_center(RubyValue self) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) {
                auto it = g_effects.find(vp->sprite_id);
                if (it != g_effects.end()) {
                    it->second.center_active = false;
                    if (it->second.zoom <= 1.0) g_effects.erase(it);   // fully inert -> reclaim
                }
            }
            return ruby_nil;
        }

        // -- Global map-default module methods (ModLoader.viewport_*) --
        RubyValue __cdecl ve_set_zoom(RubyValue, RubyValue v) {
            double z = rb_value_to_double(v);
            g_map_zoom = z > 0.0 ? z : 1.0;
            return v;
        }
        RubyValue __cdecl ve_set_enabled(RubyValue, RubyValue v) { g_map_capture = rb_truthy(v); return v; }
        RubyValue __cdecl ve_get_enabled(RubyValue) { return g_map_capture ? ruby_true : ruby_false; }
        RubyValue __cdecl ve_set_center(RubyValue, RubyValue x, RubyValue y) {
            g_map_center_x = rb_parse_int(x);
            g_map_center_y = rb_parse_int(y);
            g_map_center_active = true;
            return ruby_nil;
        }
        RubyValue __cdecl ve_auto_center(RubyValue) { g_map_center_active = false; return ruby_nil; }
    }

    void apply_viewport_effects() {
        const auto* c = mod_loader->get_config().get("viewport_effects");
        if (!(c && c->get<bool>())) {
            return;
        }
        const auto* cap = mod_loader->get_config().get("viewport_effects_capture");
        const auto* zc  = mod_loader->get_config().get("viewport_effects_zoom");
        g_map_capture = cap && cap->get<bool>();
        g_map_zoom    = zc ? zc->get<double>() : 1.0;
        if (g_map_zoom <= 0.0) g_map_zoom = 1.0;

        e_op_new    = mod_loader->at_base_offset_as<op_new_t>(op_new_offset);
        e_surf_ctor = mod_loader->at_base_offset_as<surf_ctor_t>(surface_ctor_offset);
        e_surf_init = mod_loader->at_base_offset_as<surf_init_t>(surface_init_bitmap_offset);
        e_surf_free = mod_loader->at_base_offset_as<surf_dtor_t>(surface_dtor_offset);
        e_fill_rect = mod_loader->at_base_offset_as<fill_rect_t>(fill_rect_offset);
        e_draw      = mod_loader->at_base_offset_as<draw_t>(draw_on_surface_offset);
        e_num2dbl   = mod_loader->at_base_offset_as<num2dbl_t>(num2dbl_offset);
        e_float_new = mod_loader->at_base_offset_as<float_new_t>(float_new_offset);
        g_vp_vtable = mod_loader->at_base_offset(rxviewport_vtable_offset);
        for (int i = 0; i < 4; ++i) g_leaf_vt[i] = mod_loader->at_base_offset(leaf_vtable_offsets[i]);

        mod_loader->hook_method(walker_offset, &WalkerHook::walk_hook, &WalkerHook::orig);

        // Bind the Ruby API in preinit (Ruby runtime is up by then, same as HRFix's rb_define).
        mod_loader->add_preinit_handler([] {
            // Per-viewport: any Viewport instance. Class object ptr is the same slot HRFix uses.
            RubyValue* viewport_klass = mod_loader->at_base_offset_as<RubyValue*>(0x26A0D8);
            rb_define_method(*viewport_klass, "zoom=",            vp_set_zoom,   1);
            rb_define_method(*viewport_klass, "zoom",             vp_get_zoom,   0);
            rb_define_method(*viewport_klass, "zoom_center",      vp_set_center, 2);
            rb_define_method(*viewport_klass, "zoom_auto_center", vp_auto_center, 0);

            // Global default for the auto-detected map viewport.
            mod_loader->register_ruby_method("viewport_zoom=",       ve_set_zoom);
            mod_loader->register_ruby_method("viewport_effects=",    ve_set_enabled);
            mod_loader->register_ruby_method("viewport_effects?",    ve_get_enabled);
            mod_loader->register_ruby_method("viewport_set_center",  ve_set_center);
            mod_loader->register_ruby_method("viewport_auto_center", ve_auto_center);
        });

        mod_loader->log_info("Applied ViewportEffects (per-viewport zoom; map default capture={}, zoom={})\n",
                             g_map_capture, g_map_zoom);
    }
}
