#include "ViewportEffectsHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMClasses.hpp"

#include <mutex>
#include <cstring>

namespace rm_modloader {

    // Native viewport ZOOM, reusing the engine's scene walker + stretch-blit (no RGSS sprite
    // object is created -- a plain SurfaceSprite has no zoom/wave fields anyway; zoom is just a
    // stretched M_draw_on_surface). RGSS301 base 0x10000000 (offsets = IDA addr - base):
    //   0x110820  scene walker sub_10110820(this=node, dest, POINT* origin, int* off,
    //             RECT* clip, RECT* a6). Recurses a node's drawlist with full per-node coord
    //             setup. Root = render_all_to_screen.
    //   0x10BB00  M_draw_on_surface(dest, destRect, src, srcRect, attrs) -- stretches src->dest.
    //   0x10C450  fill_rect(surface, RECT*, color)
    //   0x10B120  Surface_ctx(surface, bitcount=32)
    //   0x10B3B0  M_init_surface_bitmap(surface, w, h)  (CreateDIBSection)
    //   0x17E979  operator new(size_t)
    //   0x1A9220  &CRxViewport::vftable
    //   leaf vftables (attrs donor): RxSprite 0x1A8B78, SurfaceSprite 0x22F3CC,
    //             RxPlane 0x1A8B40, RxTilemapSprite 0x1A91EC. A SurfaceSprite's 0x38-byte
    //             attribute block lives at object+0x94 (M_copy_surface_sprite_attributes).
    namespace {
        constexpr ptrdiff_t walker_offset              = 0x110820;
        constexpr ptrdiff_t draw_on_surface_offset     = 0x10BB00;
        constexpr ptrdiff_t fill_rect_offset           = 0x10C450;
        constexpr ptrdiff_t surface_ctor_offset        = 0x10B120;
        constexpr ptrdiff_t surface_init_bitmap_offset = 0x10B3B0;
        constexpr ptrdiff_t op_new_offset              = 0x17E979;
        constexpr ptrdiff_t screen_vtable_offset       = 0x22F24C;   // &CNxScreen::vftable
        constexpr ptrdiff_t leaf_vtable_offsets[4]     = { 0x1A8B78, 0x22F3CC, 0x1A8B40, 0x1A91EC };
        constexpr int   attrs_size = 0x38;      // SurfaceSpriteAttributes
        constexpr int   attrs_at   = 0x94;      // its offset inside a SurfaceSprite

        using op_new_t    = void* (__cdecl*)(unsigned int);
        using surf_ctor_t = Surface* (__thiscall*)(Surface*, int);
        using surf_init_t = int (__thiscall*)(Surface*, int, int);
        using fill_rect_t = int (__thiscall*)(Surface*, RECT*, DWORD);
        using draw_t      = int (__thiscall*)(Surface*, RECT*, Surface*, RECT*, void*);

        op_new_t    e_op_new    = nullptr;
        surf_ctor_t e_surf_ctor = nullptr;
        surf_init_t e_surf_init = nullptr;
        fill_rect_t e_fill_rect = nullptr;
        draw_t      e_draw      = nullptr;
        const void* g_screen_vtable = nullptr;
        const void* g_leaf_vt[4] = { nullptr, nullptr, nullptr, nullptr };

        bool   g_capture = false;
        double g_zoom    = 1.0;

        Surface* g_backbuffer = nullptr;
        int      g_bb_w = 0, g_bb_h = 0;
        bool     g_in_capture = false;

        inline bool is_target(const Sprite* n) {
            // Whole-frame zoom (proof of pipeline): target the root Screen node. Its render is
            // opaque (clears to bg then draws everything), so a single capture+blit needs no
            // alpha compositing. Map-only zoom is a refinement (a specific viewport + alpha).
            return *reinterpret_cast<const void* const*>(n) == g_screen_vtable;
        }
        inline bool is_leaf(const Sprite* n) {
            const void* vt = *reinterpret_cast<const void* const*>(n);
            for (const void* lv : g_leaf_vt) if (vt == lv) return true;
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

        bool ensure_backbuffer(int w, int h) {
            if (g_backbuffer && g_bb_w == w && g_bb_h == h) return true;
            if (w <= 0 || h <= 0) return false;
            // (Re)create on first use or whenever the framebuffer resolution changes (the boot
            // screen and the in-game scene differ -> the old code bailed and never zoomed in
            // game). The old surface is leaked: resolution changes are rare, test-only.
            g_backbuffer = nullptr;
            void* mem = e_op_new(sizeof(Surface));
            if (!mem) return false;
            Surface* bb = e_surf_ctor(static_cast<Surface*>(mem), 32);
            if (!e_surf_init(bb, w, h)) return false;
            g_backbuffer = bb; g_bb_w = w; g_bb_h = h;
            mod_loader->log_info("ViewportEffects: backbuffer (re)created {}x{}\n", w, h);
            return true;
        }
    }

    struct WalkerHook : Sprite {
        // sub_10110820 is __thiscall(this, Surface* dest, POINT* origin, int* off, RECT* clip):
        // 4 stack args (it ends in `retn 10h`). IDA's decompiler shows a spurious 5th (a6).
        static void* (__thiscall Sprite::* orig)(Surface*, DWORD*, int*, RECT*);

        void* __thiscall walk_hook(Surface* dest, DWORD* origin, int* off, RECT* clip) {
            if (!g_capture || g_in_capture || !is_target(this)) {
                return (this->*orig)(dest, origin, off, clip);
            }

            RECT vr = this->rect;
            int w = vr.right - vr.left, h = vr.bottom - vr.top;
            unsigned char attrs[attrs_size];
            if (!ensure_backbuffer(vr.right, vr.bottom) || !grab_attrs(this, attrs, 0)) {
                return (this->*orig)(dest, origin, off, clip);
            }

            // 1) composite the subtree into our backbuffer via the engine's own walker.
            RECT bbfull = { 0, 0, g_bb_w, g_bb_h };
            e_fill_rect(g_backbuffer, &bbfull, 0);
            g_in_capture = true;
            (this->*orig)(g_backbuffer, origin, off, clip);
            g_in_capture = false;

            // Force a plain blend (0) so M_draw_on_surface falls through to the general
            // custom_draw blitter (CNxCustomDraw32 +16 = sub_101238E0), which calls
            // blit_stretch_setup and honours differing src/dst rect sizes. Any blend with a
            // special bit (notably 0x80000000 -> dynamic_draw) takes a 1:1 fast path that
            // ignores the dest size. Opacity/colour/tone bytes of the donor are kept.
            *reinterpret_cast<DWORD*>(attrs) = 0;

            // 2) zoom about the centre by SAMPLING a centred sub-rect of the backbuffer and
            // stretching it over the full viewport. (Enlarging the dest rect past the surface
            // instead just gets clamped to the surface bounds -> the zoom is lost.) z>=1 zooms
            // in; z<1 would need a sub-region larger than the buffer, so clamp to z>=1.
            double z = g_zoom < 1.0 ? 1.0 : g_zoom;
            int sw = static_cast<int>(w / z), sh = static_cast<int>(h / z);
            int sx = vr.left + (w - sw) / 2, sy = vr.top + (h - sh) / 2;
            RECT src = { sx, sy, sx + sw, sy + sh };

            // The stretch clipper (sub_1010CC60) offsets+clips the dest rect by the dest
            // surface's draw-offset (left/top_offset) and clip rect -- which the walker sets
            // per-sprite and leaves in a stale, tiny state by the time we blit. Reset them to
            // the full framebuffer so our stretch isn't clipped away. Safe: we skip the normal
            // render this frame, and the walker re-sets them next frame.
            dest->left_offset = 0;
            dest->top_offset  = 0;
            dest->rect.left   = 0;
            dest->rect.top    = 0;
            dest->rect.right  = g_bb_w;
            dest->rect.bottom = g_bb_h;
            e_draw(dest, &vr, g_backbuffer, &src, attrs);
            return this;
        }
    };

    void* (__thiscall Sprite::* WalkerHook::orig)(Surface*, DWORD*, int*, RECT*) = nullptr;

    void apply_viewport_effects() {
        const auto* c = mod_loader->get_config().get("viewport_effects");
        if (!(c && c->get<bool>())) {
            return;
        }
        const auto* cap = mod_loader->get_config().get("viewport_effects_capture");
        const auto* zc  = mod_loader->get_config().get("viewport_effects_zoom");
        g_capture = cap && cap->get<bool>();
        g_zoom    = zc ? zc->get<double>() : 1.0;
        if (g_zoom <= 0.0) g_zoom = 1.0;

        e_op_new    = mod_loader->at_base_offset_as<op_new_t>(op_new_offset);
        e_surf_ctor = mod_loader->at_base_offset_as<surf_ctor_t>(surface_ctor_offset);
        e_surf_init = mod_loader->at_base_offset_as<surf_init_t>(surface_init_bitmap_offset);
        e_fill_rect = mod_loader->at_base_offset_as<fill_rect_t>(fill_rect_offset);
        e_draw      = mod_loader->at_base_offset_as<draw_t>(draw_on_surface_offset);
        g_screen_vtable = mod_loader->at_base_offset(screen_vtable_offset);
        for (int i = 0; i < 4; ++i) g_leaf_vt[i] = mod_loader->at_base_offset(leaf_vtable_offsets[i]);

        mod_loader->hook_method(walker_offset, &WalkerHook::walk_hook, &WalkerHook::orig);
        mod_loader->log_info("Applied ViewportEffects (zoom-via-blit, capture={}, zoom={})\n", g_capture, g_zoom);
    }
}
