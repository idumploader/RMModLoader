#include "ViewportEffectsHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMClasses.hpp"
#include "../RMGlobal.hpp"

#include <mutex>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>
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
        // Engine transform kernel (RxSprite::render) + its ctor/set_surface, for native rotation.
        constexpr ptrdiff_t rxsprite_ctor_offset       = 0x01CE40;   // RxSprite_ctx(this, ancestor) -- true entry (prologue); 0x1CE50 lands mid-SEH
        constexpr ptrdiff_t rxsprite_render_offset     = 0x01E780;   // RxSprite::render(this, dest, clip)
        constexpr ptrdiff_t rxsprite_setsurf_offset    = 0x01D180;   // RxSprite_set_surface(this, Surface*, a3)
        constexpr ptrdiff_t img_off8_offset            = 0x11F9F0;   // surface_get_image_off8 (top-row px ptr)
        constexpr ptrdiff_t stride_offset              = 0x007E30;   // surface_get_stride_bytes
        // RxSprite field offsets (from IDA CRxSprite layout):
        constexpr int SP_RECT     = 0x08;    // base Sprite::rect = dest rect (sprite_copy_rect src)
        constexpr int SP_SRCRECT  = 0xCC;    // which region of the surface to sample
        constexpr int SP_COORD    = 0xDC;    // POINT: rotation pivot in DEST coords
        constexpr int SP_ORIGIN   = 0xE4;    // POINT ox/oy: rotation pivot in SRC coords
        constexpr int SP_ZOOMX    = 0xF0;    // double
        constexpr int SP_ZOOMY    = 0xF8;    // double
        constexpr int SP_ANGLE    = 0x100;   // double (radians)
        constexpr int SP_MIRROR   = 0x120;   // BOOL (horizontal mirror)
        constexpr int SP_WAVE_AMP   = 0x108; // DWORD wave amplitude (px); >0 enables the wave loop
        constexpr int SP_WAVE_LEN   = 0x10C; // DWORD wave length
        constexpr int SP_WAVE_SPD   = 0x110; // DWORD wave speed (we drive phase, so 0)
        constexpr int SP_WAVE_PHASE = 0x118; // double running phase
        constexpr int SP_ROTDIRTY = 0x150;   // gap140[4]: re-rotate flag, set on any change
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
        using sp_ctor_t   = void* (__thiscall*)(void* self, void* ancestor);
        using sp_render_t = int   (__thiscall*)(void* self, Surface* dest, RECT* clip);
        using sp_setsurf_t= Surface* (__thiscall*)(void* self, Surface* surf, int a3);
        using img_off8_t  = uint32_t* (__thiscall*)(Surface*);   // top-row pixel pointer
        using stride_t    = int (__thiscall*)(Surface*);         // row stride in bytes

        op_new_t    e_op_new    = nullptr;
        surf_ctor_t e_surf_ctor = nullptr;
        surf_init_t e_surf_init = nullptr;
        surf_dtor_t e_surf_free = nullptr;
        fill_rect_t e_fill_rect = nullptr;
        draw_t      e_draw      = nullptr;
        num2dbl_t   e_num2dbl   = nullptr;
        float_new_t e_float_new = nullptr;
        sp_ctor_t    e_sp_ctor    = nullptr;
        sp_render_t  e_sp_render  = nullptr;
        sp_setsurf_t e_sp_setsurf = nullptr;
        img_off8_t   e_img_off8   = nullptr;
        stride_t     e_stride     = nullptr;
        void*        g_sprite     = nullptr;   // standalone RxSprite (ancestor=null), built lazily
        std::vector<uint32_t> g_blur_tmp;      // scratch for the separable box blur
        std::vector<uint32_t> g_zb_grid;       // coarse grid for the zoom-blur bilinear upsample
        bool g_zb_hq = false;                  // debug: full-res zoom blur (no STEP grid) to compare
        const void* g_vp_vtable = nullptr;
        const void* g_leaf_vt[4] = { nullptr, nullptr, nullptr, nullptr };

        // One viewport's effect. center_* is the zoom focus in screen pixels (the captured
        // content lands at absolute coords in the backbuffer); inactive -> focus on the
        // viewport centre. All fields default to "no-op"; the walker skips an inert effect.
        struct VPEffect {
            double zoom = 1.0;                 // >1 zooms in about the focus
            bool   center_active = false;
            int    center_x = 0, center_y = 0;
            bool   flip_x = false, flip_y = false;   // mirror (engine attr bits 0x4000 / 0x8000)
            double wave_amp = 0.0;             // horizontal ripple amplitude in px
            double wave_length = 180.0;        // vertical period in px
            double wave_speed = 0.0;           // phase advance per frame (rad)
            double wave_phase = 0.0;           // running phase (advanced by the walker)
            double angle = 0.0;                // rotation in degrees (0 = none)
            int    blur = 0;                   // box-blur radius in px (0 = none)
            int    zoom_blur = 0;              // zoom/"warp" blur strength 0..100 (0 = none)
            int    radial_blur = 0;            // radial/spin blur strength 0..100 (0 = none)
            bool wave_on() const { return wave_amp != 0.0 && wave_length > 0.0; }
            bool rotates() const { return angle != 0.0 || flip_x || flip_y; }
            bool active() const { return zoom > 1.0 || flip_x || flip_y || wave_on() || angle != 0.0 || blur > 0 || zoom_blur > 0 || radial_blur > 0; }
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

        // Decide which effect applies to this node this frame, or nullptr. Returns a pointer to
        // the live effect so the walker can advance its wave phase. Explicit per-viewport effect
        // wins; otherwise the global map default (kept in a persistent struct so its phase runs).
        VPEffect g_map_effect;
        inline VPEffect* resolve_effect(const Sprite* n) {
            if (!is_viewport(n)) return nullptr;
            auto it = g_effects.find(n->sprite_id);
            if (it != g_effects.end() && it->second.active()) return &it->second;
            if (g_map_capture && g_map_zoom > 1.0 && has_tilemap(n, 0)) {
                g_map_effect.zoom = g_map_zoom;
                g_map_effect.center_active = g_map_center_active;
                g_map_effect.center_x = g_map_center_x;
                g_map_effect.center_y = g_map_center_y;
                return &g_map_effect;
            }
            return nullptr;
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

        // Lazily build one standalone RxSprite (ancestor=null, so it is in NO drawlist and the
        // scene walk never visits it). We reuse it every frame as the engine's transform kernel:
        // point it at the backbuffer, set angle/zoom/mirror, call RxSprite::render onto the screen.
        void* ensure_sprite() {
            if (g_sprite) return g_sprite;
            if (!e_op_new || !e_sp_ctor) return nullptr;
            void* mem = e_op_new(0x2C0);                 // sizeof(RxSprite)
            if (!mem) return nullptr;
            g_sprite = e_sp_ctor(mem, nullptr);          // full ctor chain; ancestor=null is guarded
            return g_sprite;
        }
        template<typename T> inline void sp_set(void* obj, int off, const T& v) {
            *reinterpret_cast<T*>(reinterpret_cast<char*>(obj) + off) = v;
        }

        // Separable box blur of a BGRA region in place, via the engine's pixel pointer
        // (surface_get_image_off8 = top-row, top-down y*stride+x like the engine itself uses).
        // Two O(1)-per-pixel sliding-window passes (horizontal -> packed tmp -> vertical). The
        // engine has no blur primitive, so this is the one genuinely hand-rolled per-pixel cost.
        void box_blur(uint32_t* base, int stride, int x0, int y0, int x1, int y1, int r) {
            int W = x1 - x0, H = y1 - y0;
            if (W <= 0 || H <= 0 || r < 1) return;
            if (static_cast<int>(g_blur_tmp.size()) < W * H) g_blur_tmp.resize(W * H);
            uint32_t* tmp = g_blur_tmp.data();
            for (int y = 0; y < H; ++y) {                       // horizontal: region -> packed tmp
                uint32_t* row = base + (y0 + y) * stride + x0;
                uint32_t* trow = tmp + y * W;
                int sB = 0, sG = 0, sR = 0, sA = 0, lo = 0, hi = -1, cnt = 0;
                for (int x = 0; x < W; ++x) {
                    int nh = x + r > W - 1 ? W - 1 : x + r;
                    int nl = x - r < 0 ? 0 : x - r;
                    for (; hi < nh; ) { uint32_t p = row[++hi]; sB += p & 0xFF; sG += (p >> 8) & 0xFF; sR += (p >> 16) & 0xFF; sA += (p >> 24) & 0xFF; ++cnt; }
                    for (; lo < nl; ++lo) { uint32_t p = row[lo]; sB -= p & 0xFF; sG -= (p >> 8) & 0xFF; sR -= (p >> 16) & 0xFF; sA -= (p >> 24) & 0xFF; --cnt; }
                    trow[x] = (sB / cnt) | ((sG / cnt) << 8) | ((sR / cnt) << 16) | ((sA / cnt) << 24);
                }
            }
            for (int x = 0; x < W; ++x) {                       // vertical: packed tmp -> region
                int sB = 0, sG = 0, sR = 0, sA = 0, lo = 0, hi = -1, cnt = 0;
                for (int y = 0; y < H; ++y) {
                    int nh = y + r > H - 1 ? H - 1 : y + r;
                    int nl = y - r < 0 ? 0 : y - r;
                    for (; hi < nh; ) { uint32_t p = tmp[(++hi) * W + x]; sB += p & 0xFF; sG += (p >> 8) & 0xFF; sR += (p >> 16) & 0xFF; sA += (p >> 24) & 0xFF; ++cnt; }
                    for (; lo < nl; ++lo) { uint32_t p = tmp[lo * W + x]; sB -= p & 0xFF; sG -= (p >> 8) & 0xFF; sR -= (p >> 16) & 0xFF; sA -= (p >> 24) & 0xFF; --cnt; }
                    base[(y0 + y) * stride + x0 + x] = (sB / cnt) | ((sG / cnt) << 8) | ((sR / cnt) << 16) | ((sA / cnt) << 24);
                }
            }
        }

        // Directional multi-tap blur about (cx,cy). Each output pixel averages `taps` samples,
        // each read at C + M_k*(p-C) for a per-tap 2x2 matrix M_k. Contracting matrices (uniform
        // scale <1) give a zoom/"warp" blur; rotation matrices give a radial/spin blur. Shared
        // structure for both: compute on a STEP=2 grid (4x fewer tap loops) + branchless avg2
        // upsample, with the central box recomputed at full res (streaks vanish toward the centre,
        // so the grid would blockify the sharp player sprite there).
        struct TapMat { double a, b, c, d; };   // sx = cx + a*dx + b*dy ; sy = cy + c*dx + d*dy
        void directional_blur(uint32_t* base, int stride, int x0, int y0, int x1, int y1,
                              int cx, int cy, const TapMat* m, int taps) {
            int W = x1 - x0, H = y1 - y0;
            if (W <= 0 || H <= 0 || taps < 1) return;
            // one pixel's averaged sample (dx,dy are relative to the centre).
            auto sample = [&](int dx, int dy) -> uint32_t {
                int sB = 0, sG = 0, sR = 0, sA = 0;
                for (int k = 0; k < taps; ++k) {
                    int sx = cx + static_cast<int>(m[k].a * dx + m[k].b * dy);
                    int sy = cy + static_cast<int>(m[k].c * dx + m[k].d * dy);
                    if (sx < x0) sx = x0; else if (sx >= x1) sx = x1 - 1;
                    if (sy < y0) sy = y0; else if (sy >= y1) sy = y1 - 1;
                    uint32_t p = base[sy * stride + sx];
                    sB += p & 0xFF; sG += (p >> 8) & 0xFF; sR += (p >> 16) & 0xFF; sA += (p >> 24) & 0xFF;
                }
                return (sB / taps) | ((sG / taps) << 8) | ((sR / taps) << 16) | ((sA / taps) << 24);
            };

            if (g_zb_hq) {                                   // debug: full-res, no grid
                if (static_cast<int>(g_blur_tmp.size()) < W * H) g_blur_tmp.resize(W * H);
                uint32_t* tmp = g_blur_tmp.data();
                for (int y = 0; y < H; ++y)
                    for (int x = 0; x < W; ++x)
                        tmp[y * W + x] = sample(x0 + x - cx, y0 + y - cy);
                for (int y = 0; y < H; ++y)
                    for (int x = 0; x < W; ++x)
                        base[(y0 + y) * stride + x0 + x] = tmp[y * W + x];
                return;
            }

            constexpr int STEP = 2;
            int gw = W / STEP + 2, gh = H / STEP + 2;
            if (static_cast<int>(g_zb_grid.size()) < gw * gh) g_zb_grid.resize(gw * gh);
            uint32_t* grid = g_zb_grid.data();
            for (int gy = 0; gy < gh; ++gy) {
                int y = gy * STEP; if (y > H - 1) y = H - 1;
                for (int gx = 0; gx < gw; ++gx) {
                    int x = gx * STEP; if (x > W - 1) x = W - 1;
                    grid[gy * gw + gx] = sample(x0 + x - cx, y0 + y - cy);
                }
            }
            // crisp central box at full res (stashed before the upsample overwrites base).
            int Rx = W * 18 / 100, Ry = H * 18 / 100;
            int bx0 = cx - Rx < x0 ? x0 : cx - Rx, by0 = cy - Ry < y0 ? y0 : cy - Ry;
            int bx1 = cx + Rx > x1 ? x1 : cx + Rx, by1 = cy + Ry > y1 ? y1 : cy + Ry;
            int bw = bx1 - bx0, bh = by1 - by0;
            if (bw > 0 && bh > 0) {
                if (static_cast<int>(g_blur_tmp.size()) < bw * bh) g_blur_tmp.resize(bw * bh);
                uint32_t* bt = g_blur_tmp.data();
                for (int yy = 0; yy < bh; ++yy)
                    for (int xx = 0; xx < bw; ++xx)
                        bt[yy * bw + xx] = sample(bx0 + xx - cx, by0 + yy - cy);
            }
            // avg2 upsample: average of two packed BGRA pixels in one branchless bit-trick.
            auto avg2 = [](uint32_t a, uint32_t b) { return (a & b) + (((a ^ b) >> 1) & 0x7F7F7F7Fu); };
            for (int y = 0; y < H; ++y) {
                int gy = y >> 1, wy = y & 1;
                uint32_t* drow = base + (y0 + y) * stride + x0;
                const uint32_t* g0 = grid + gy * gw;
                const uint32_t* g1 = grid + (gy + 1) * gw;
                if (!wy) {
                    for (int x = 0; x < W; x += 2) {
                        int gx = x >> 1; uint32_t c00 = g0[gx];
                        drow[x] = c00;
                        if (x + 1 < W) drow[x + 1] = avg2(c00, g0[gx + 1]);
                    }
                } else {
                    for (int x = 0; x < W; x += 2) {
                        int gx = x >> 1; uint32_t c00 = g0[gx], c01 = g1[gx];
                        drow[x] = avg2(c00, c01);
                        if (x + 1 < W) drow[x + 1] = avg2(avg2(c00, g0[gx + 1]), avg2(c01, g1[gx + 1]));
                    }
                }
            }
            if (bw > 0 && bh > 0) {                       // paste the crisp full-res centre back
                uint32_t* bt = g_blur_tmp.data();
                for (int yy = 0; yy < bh; ++yy)
                    for (int xx = 0; xx < bw; ++xx)
                        base[(by0 + yy) * stride + bx0 + xx] = bt[yy * bw + xx];
            }
        }

        constexpr int BLUR_TAPS = 10;
        // Combined motion blur: zoom ("warp", contract toward the centre) and radial (spin) fuse
        // into ONE directional pass -- the per-tap matrix is scale * rotation (a spiral). zoom
        // alone = pure scale, radial alone = pure rotation, both = spiral, all at one pass. (This
        // is why stacking the two need not cost 2x: Zeus reuses its sprite copies, we reuse taps.)
        void motion_blur(uint32_t* base, int stride, int x0, int y0, int x1, int y1,
                         int cx, int cy, int zoom_s, int radial_s) {
            if (zoom_s <= 0 && radial_s <= 0) return;
            double sp   = (zoom_s   > 100 ? 100 : zoom_s)   / 100.0 * 0.40;   // up to 40% contraction
            double maxr = (radial_s > 100 ? 100 : radial_s) / 100.0 * 0.25;   // half-arc, radians
            TapMat m[BLUR_TAPS];
            for (int k = 0; k < BLUR_TAPS; ++k) {
                double f = 1.0 - sp * k / (BLUR_TAPS - 1);
                double ang = -maxr + 2.0 * maxr * k / (BLUR_TAPS - 1);
                double c = std::cos(ang), s = std::sin(ang);
                m[k] = { f * c, -f * s, f * s, f * c };
            }
            directional_blur(base, stride, x0, y0, x1, y1, cx, cy, m, BLUR_TAPS);
        }
    }

    struct WalkerHook : Sprite {
        // sub_10110820 is __thiscall(this, Surface* dest, POINT* origin, int* off, RECT* clip):
        // 4 stack args (it ends in `retn 10h`). IDA's decompiler shows a spurious 5th (a6).
        static void* (__thiscall Sprite::* orig)(Surface*, DWORD*, int*, RECT*);

        void* __thiscall walk_hook(Surface* dest, DWORD* origin, int* off, RECT* clip) {
            VPEffect* eff = resolve_effect(this);
            if (g_in_capture || !eff) {
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

            // Blur the captured region in place (before any zoom/rotate blit), so it composes
            // with every other effect. Engine has no blur -> our own CPU pass (the heaviest bit).
            if ((eff->blur > 0 || eff->zoom_blur > 0 || eff->radial_blur > 0) && e_img_off8 && e_stride) {
                uint32_t* px = e_img_off8(g_backbuffer);
                int stride_px = e_stride(g_backbuffer) / 4;   // SIGNED: negative for a bottom-up DIB
                if (px && stride_px != 0) {                   // base is the top row, so -stride walks down
                    int bcx = eff->center_active ? eff->center_x : (vr.left + vr.right) / 2;
                    int bcy = eff->center_active ? eff->center_y : (vr.top + vr.bottom) / 2;
                    if (eff->blur > 0)
                        box_blur(px, stride_px, vr.left, vr.top, vr.right, vr.bottom, eff->blur);
                    if (eff->zoom_blur > 0 || eff->radial_blur > 0)   // fused: one pass for both
                        motion_blur(px, stride_px, vr.left, vr.top, vr.right, vr.bottom, bcx, bcy,
                                    eff->zoom_blur, eff->radial_blur);
                }
            }

            // Blend 0x10000: routes to the general custom_draw blitter (stretches) AND skips
            // its opacity==255 fast path -- which is an opaque copy that writes transparent
            // source pixels as black (that black-screen over the HUD). The non-fast path does
            // per-pixel alpha so the transparent parts of this map layer show the HUD beneath.
            // (Plain 0x80000000 -> dynamic_draw = 1:1 no stretch; blend 0 -> opaque, blacks.)
            // This path handles pure zoom/wave; flip and rotation go through the RxSprite kernel
            // below (the mirror bit 0x4000 is ignored by this 0x10000 kernel anyway).
            *reinterpret_cast<DWORD*>(attrs) = 0x10000;

            // 2) zoom about the focus by SAMPLING a sub-rect of the backbuffer and stretching it
            // over the full viewport. (Enlarging the dest rect past the surface instead just gets
            // clamped -> the zoom is lost.) z>=1 zooms in; z<1 would need a sub-region larger than
            // the buffer, so we never store zoom<=1 as active.
            double z = eff->zoom < 1.0 ? 1.0 : eff->zoom;
            int sw = static_cast<int>(w / z), sh = static_cast<int>(h / z);
            // Centre the sampled sub-rect on the focus point (viewport centre by default, or a
            // script-set screen pixel for follow-cam). Clamp inside the viewport so we never
            // sample outside the captured layer (which would smear the edge / show 0s).
            int cx = eff->center_active ? eff->center_x : (vr.left + w / 2);
            int cy = eff->center_active ? eff->center_y : (vr.top + h / 2);
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

            // Rotation / flip path: hand the captured backbuffer to the engine's own transform
            // kernel (RxSprite::render). It rotates the source into an internal buffer (angle),
            // scales via zoom_x/zoom_y and flips by their sign. Only triggers when angle/flip is
            // set; pure zoom/wave stay on the hand-rolled path above.
            if (eff->rotates() && e_sp_render) {
                void* spr = ensure_sprite();
                if (spr) {
                    e_sp_setsurf(spr, g_backbuffer, 0);
                    // The rotate kernel scales via zoom_x/zoom_y (it divides the mapped source
                    // coord by them), NOT via the src->dst rect ratio. So here we sample the FULL
                    // captured region and let zoom_x/zoom_y do the zoom -- mixing both (a pre-
                    // shrunk src AND zoom_x) double-counts and reads out of bounds (crash). Flip
                    // is the SIGN of the scale; the engine mirrors the axis about the pivot.
                    RECT full = { vr.left, vr.top, vr.right, vr.bottom };
                    int px = eff->center_active ? eff->center_x : (vr.left + vr.right) / 2;
                    int py = eff->center_active ? eff->center_y : (vr.top + vr.bottom) / 2;
                    POINT pivot = { px, py };               // same point in dest and src (full region)
                    sp_set<RECT>(spr, SP_RECT, vr);
                    sp_set<RECT>(spr, SP_SRCRECT, full);
                    sp_set<POINT>(spr, SP_COORD, pivot);
                    sp_set<POINT>(spr, SP_ORIGIN, pivot);
                    sp_set<double>(spr, SP_ZOOMX, eff->flip_x ? -z : z);   // z = zoom magnitude (>=1)
                    sp_set<double>(spr, SP_ZOOMY, eff->flip_y ? -z : z);
                    // Pure flip (angle 0) still needs the rotate branch; nudge to a full turn.
                    sp_set<double>(spr, SP_ANGLE, eff->angle != 0.0 ? eff->angle : 360.0);
                    sp_set<int>(spr, SP_MIRROR, 0);
                    // Wave does NOT compose with rotation: the kernel's per-scanline wave uses
                    // different length/phase units (it mostly shrinks the edges instead of
                    // rippling), so we leave it off here. Pure wave / wave+zoom stay on the cheap
                    // hand-rolled strip path above. (TODO: RE sub_1001F000's units to unify.)
                    sp_set<int>(spr, SP_WAVE_AMP, 0);
                    // Our proven alpha-stretch blend; the sprite's default opaque dynamic_draw
                    // (0x80000810) drew nothing from our synthetic backbuffer (black screen).
                    sp_set<DWORD>(spr, attrs_at, 0x10000);
                    sp_set<int>(spr, SP_ROTDIRTY, 1);
                    RECT clip = vr;
                    e_sp_render(spr, dest, &clip);
                    return this;
                }
            }

            if (!eff->wave_on()) {
                e_draw(dest, &vr, g_backbuffer, &src, attrs);  // single stretch blit
                return this;
            }

            // 3) wave: slice the source into horizontal strips and shift each by
            // amp*sin(phase + y/length). The engine has no wave primitive, so we compose it from
            // per-strip stretch blits. To avoid black edges where the content slides away, we
            // OVERSCAN: inset the sampled region by the amplitude and keep every dst strip full
            // width, shifting the SOURCE within the captured region (clamped). Costs a ~amplitude
            // px zoom-in but never exposes the cleared background. STRIP trades quality for cost
            // (smaller = smoother + more blits/frame; software renderer -> keep modest).
            eff->wave_phase += eff->wave_speed;
            constexpr int STRIP = 6;
            const double two_pi = 6.283185307179586;
            int margin = static_cast<int>(std::ceil(std::fabs(eff->wave_amp))) * sw / w;
            if (margin < 1) margin = 1;
            int isx = sx + margin, isw = sw - 2 * margin;   // inset sample window
            if (isw < 1) { isx = sx; isw = sw; }            // viewport too small to overscan
            for (int dy = vr.top; dy < vr.bottom; dy += STRIP) {
                int dh = (dy + STRIP > vr.bottom) ? (vr.bottom - dy) : STRIP;
                int ssy = sy + (dy - vr.top) * sh / h;
                int ssh = dh * sh / h; if (ssh < 1) ssh = 1;
                double off = eff->wave_amp * std::sin(eff->wave_phase + (double)(dy - vr.top) * two_pi / eff->wave_length);
                int ssx = isx - static_cast<int>(off * sw / w);   // shift source opposite the visual move
                if (ssx < sx) ssx = sx;                            // clamp inside captured region
                if (ssx + isw > sx + sw) ssx = sx + sw - isw;
                RECT srcS = { ssx, ssy, ssx + isw, ssy + ssh };
                RECT dstS = { vr.left, dy, vr.right, dy + dh };    // full width -> no black gap
                e_draw(dest, &dstS, g_backbuffer, &srcS, attrs);
            }
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
        // Drop a now-inert entry so the map doesn't accumulate no-op effects.
        inline void reclaim_if_inert(std::unordered_map<DWORD, VPEffect>::iterator it) {
            if (it != g_effects.end() && !it->second.active()) g_effects.erase(it);
        }
        RubyValue __cdecl vp_set_zoom(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (!vp) return v;
            double z = rb_value_to_double(v);
            g_effects[vp->sprite_id].zoom = z > 0.0 ? z : 1.0;
            reclaim_if_inert(g_effects.find(vp->sprite_id));
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
                if (it != g_effects.end()) { it->second.center_active = false; reclaim_if_inert(it); }
            }
            return ruby_nil;
        }
        RubyValue __cdecl vp_set_flip_x(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) { g_effects[vp->sprite_id].flip_x = rb_truthy(v); reclaim_if_inert(g_effects.find(vp->sprite_id)); }
            return v;
        }
        RubyValue __cdecl vp_set_flip_y(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) { g_effects[vp->sprite_id].flip_y = rb_truthy(v); reclaim_if_inert(g_effects.find(vp->sprite_id)); }
            return v;
        }
        // wave(amplitude_px, length_px, speed_rad_per_frame). amplitude 0 turns it off.
        RubyValue __cdecl vp_set_wave(RubyValue self, RubyValue amp, RubyValue length, RubyValue speed) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (!vp) return ruby_nil;
            VPEffect& e = g_effects[vp->sprite_id];
            e.wave_amp = rb_value_to_double(amp);
            double len = rb_value_to_double(length);
            if (len > 0.0) e.wave_length = len;
            e.wave_speed = rb_value_to_double(speed);
            reclaim_if_inert(g_effects.find(vp->sprite_id));
            return ruby_nil;
        }
        RubyValue __cdecl vp_set_angle(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) { g_effects[vp->sprite_id].angle = rb_value_to_double(v); reclaim_if_inert(g_effects.find(vp->sprite_id)); }
            return v;
        }
        RubyValue __cdecl vp_set_blur(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) {
                int r = rb_parse_int(v);
                if (r < 0) r = 0; else if (r > 64) r = 64;   // clamp (cost + sanity)
                g_effects[vp->sprite_id].blur = r;
                reclaim_if_inert(g_effects.find(vp->sprite_id));
            }
            return v;
        }
        RubyValue __cdecl vp_set_zoom_blur(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) {
                int s = rb_parse_int(v);
                if (s < 0) s = 0; else if (s > 100) s = 100;
                g_effects[vp->sprite_id].zoom_blur = s;
                reclaim_if_inert(g_effects.find(vp->sprite_id));
            }
            return v;
        }
        RubyValue __cdecl vp_set_radial_blur(RubyValue self, RubyValue v) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) {
                int s = rb_parse_int(v);
                if (s < 0) s = 0; else if (s > 100) s = 100;
                g_effects[vp->sprite_id].radial_blur = s;
                reclaim_if_inert(g_effects.find(vp->sprite_id));
            }
            return v;
        }
        RubyValue __cdecl vp_wave_off(RubyValue self) {
            RxViewport* vp = rgss_native<RxViewport>(self);
            if (vp) {
                auto it = g_effects.find(vp->sprite_id);
                if (it != g_effects.end()) { it->second.wave_amp = 0.0; reclaim_if_inert(it); }
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
        RubyValue __cdecl ve_set_zb_hq(RubyValue, RubyValue v) { g_zb_hq = rb_truthy(v); return v; }
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
        e_sp_ctor    = mod_loader->at_base_offset_as<sp_ctor_t>(rxsprite_ctor_offset);
        e_sp_render  = mod_loader->at_base_offset_as<sp_render_t>(rxsprite_render_offset);
        e_sp_setsurf = mod_loader->at_base_offset_as<sp_setsurf_t>(rxsprite_setsurf_offset);
        e_img_off8   = mod_loader->at_base_offset_as<img_off8_t>(img_off8_offset);
        e_stride     = mod_loader->at_base_offset_as<stride_t>(stride_offset);
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
            rb_define_method(*viewport_klass, "flip_x=",          vp_set_flip_x, 1);
            rb_define_method(*viewport_klass, "flip_y=",          vp_set_flip_y, 1);
            rb_define_method(*viewport_klass, "wave",             vp_set_wave,   3);
            rb_define_method(*viewport_klass, "wave_off",         vp_wave_off,   0);
            rb_define_method(*viewport_klass, "angle=",           vp_set_angle,  1);
            rb_define_method(*viewport_klass, "blur=",            vp_set_blur,   1);
            rb_define_method(*viewport_klass, "zoom_blur=",       vp_set_zoom_blur, 1);
            rb_define_method(*viewport_klass, "radial_blur=",     vp_set_radial_blur, 1);

            // Global default for the auto-detected map viewport.
            mod_loader->register_ruby_method("viewport_zoom=",       ve_set_zoom);
            mod_loader->register_ruby_method("viewport_effects=",    ve_set_enabled);
            mod_loader->register_ruby_method("viewport_effects?",    ve_get_enabled);
            mod_loader->register_ruby_method("viewport_set_center",  ve_set_center);
            mod_loader->register_ruby_method("viewport_auto_center", ve_auto_center);
            mod_loader->register_ruby_method("viewport_zoom_blur_hq=", ve_set_zb_hq);   // debug A/B
        });

        mod_loader->log_info("Applied ViewportEffects (per-viewport zoom; map default capture={}, zoom={})\n",
                             g_map_capture, g_map_zoom);
    }
}
