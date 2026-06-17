#include "SpriteDisposeFixHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMClasses.hpp"
#include "../Ruby.hpp"

#include <unordered_set>
#include <mutex>

namespace rm_modloader {

    // RGSS301 base 0x10000000. Offsets resolved from the binary (see IDA notes):
    //   0x110290  Sprite_ctx                 base CNxSprite constructor
    //   0x110400  CNxSprite_destroy_base     base destructor body (detach + cascade)
    //   0x1103D0  Sprite_dtx                 CNxSprite scalar deleting destructor
    //   0x110520  Sprite_drawlist_remove     unlink child from container's drawlist
    //                                        (called by destroy_base AND set_ancestor)
    //   0x12B80/0x10930/0x18450  RB{Sprite,Plane,Window}_dispose  ruby dispose entry
    namespace {
        constexpr ptrdiff_t sprite_ctor_offset            = 0x110290;
        constexpr ptrdiff_t sprite_destroy_base_offset    = 0x110400;
        constexpr ptrdiff_t sprite_scalar_dtor_offset     = 0x1103D0;
        constexpr ptrdiff_t sprite_drawlist_remove_offset = 0x110520;

        constexpr ptrdiff_t rb_sprite_dispose_offset = 0x12B80;
        constexpr ptrdiff_t rb_plane_dispose_offset  = 0x10930;
        constexpr ptrdiff_t rb_window_dispose_offset = 0x18450;

        // Lifetime registry. A drawable is "live" between its base ctor and the end
        // of its base destructor; afterwards it is "dead" (memory freed or about to
        // be). We keep two sets so a destroyed object is positively known to be dead
        // -- never confused with an object that was simply never tracked (which must
        // be treated as live, i.e. left alone). On reuse of a freed address the ctor
        // moves it back from dead to live.
        std::unordered_set<const void*> g_live;
        std::unordered_set<const void*> g_dead;
        std::mutex g_mutex;

        inline void mark_live(const void* obj) {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_dead.erase(obj);
            g_live.insert(obj);
        }

        inline void mark_dead(const void* obj) {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_live.erase(obj);
            g_dead.insert(obj);
        }

        inline bool is_live(const void* obj) {
            std::lock_guard<std::mutex> lock(g_mutex);
            return g_live.find(obj) != g_live.end();
        }

        inline bool is_dead(const void* obj) {
            std::lock_guard<std::mutex> lock(g_mutex);
            return g_dead.find(obj) != g_dead.end();
        }

        // Ruby DATA wrapper for a drawable. RGSS stores the native C++ object
        // pointer at DATA_PTR(self)+8 for Sprite/Plane/Window; it is also the
        // registry key (base subobject at offset 0).
        struct DrawableRubyWrapper {
            void* reserved0; // +0
            void* reserved1; // +4
            void* native;    // +8 -> CNxSprite-derived object
        };

        // If self's native object has already been destroyed (e.g. cascade-freed by
        // a disposed Viewport) but the Ruby wrapper still points at it, null the
        // wrapper pointer and report handled. This stops RBxxx_dispose from
        // dereferencing the dangling (and possibly heap-reused) native vtable, and
        // makes disposed? honest. Uses is_dead (positive) so a live-but-untracked
        // object is never wrongly neutralized.
        inline bool neutralize_if_dead(RubyValue self) {
            auto* wrapper = get_rb_data_data<DrawableRubyWrapper>(self);
            if (wrapper && wrapper->native && is_dead(wrapper->native)) {
                wrapper->native = nullptr;
                return true;
            }
            return false;
        }
    }

    // Hooks on the common CNxSprite base ctor/dtor. Every drawable (Sprite, Plane,
    // Viewport, Window, Screen, tilemap sprites) funnels through these, so they give
    // complete, single-point lifetime tracking.
    struct SpriteLifetimeHook : Sprite {
        static Sprite* (__thiscall Sprite::* orig_ctor)(Screen* ancestor);
        static int (__thiscall Sprite::* orig_destroy_base)();
        static void* (__thiscall Sprite::* orig_scalar_dtor)(char flags);
        static int (__thiscall Sprite::* orig_drawlist_remove)(Sprite* child);

        Sprite* __thiscall ctor_hook(Screen* ancestor) {
            Sprite* result = (this->*orig_ctor)(ancestor);
            mark_live(this);
            return result;
        }

        // First/legit destruction. Run the original body FIRST (it cascades into
        // children, each of which unlinks from THIS via Sprite_drawlist_remove --
        // so THIS must still count as live during its own cascade), then mark dead.
        int __thiscall destroy_base_hook() {
            int result = (this->*orig_destroy_base)();
            mark_dead(this);
            return result;
        }

        // CNxSprite scalar deleting destructor. After the first destruction the
        // vftable is downgraded to CNxSprite, so a second destruction (Ruby `super`,
        // or a container disposing an already-freed child) dispatches here. If the
        // object is no longer live, skip: prevents the double vector-dtor + double
        // operator delete (heap corruption).
        void* __thiscall scalar_dtor_hook(char flags) {
            if (!is_live(this)) {
                return this; // duplicate destruction of an already-freed object
            }
            return (this->*orig_scalar_dtor)(flags);
        }

        // Sprite_drawlist_remove(container=this, child). Reached from both
        // CNxSprite_destroy_base (unlink from ancestor on destruction) and
        // Sprite_set_ancestor (unlink from old ancestor on viewport change). If the
        // container has already been destroyed, its drawlist is gone -- the original
        // would run std::find over freed memory and fault (the 0xC0000005 in
        // stl_find, both the direct F8 crash and the deferred on-load one). Skipping
        // is safe: a freed container holds no reference back to the child.
        int __thiscall drawlist_remove_hook(Sprite* child) {
            if (is_dead(this)) {
                return 0;
            }
            return (this->*orig_drawlist_remove)(child);
        }
    };

    Sprite* (__thiscall Sprite::* SpriteLifetimeHook::orig_ctor)(Screen*) = nullptr;
    int (__thiscall Sprite::* SpriteLifetimeHook::orig_destroy_base)() = nullptr;
    void* (__thiscall Sprite::* SpriteLifetimeHook::orig_scalar_dtor)(char) = nullptr;
    int (__thiscall Sprite::* SpriteLifetimeHook::orig_drawlist_remove)(Sprite*) = nullptr;

    // Idempotency gate at the Ruby dispose entry (Sprite/Plane/Window#dispose, also
    // reached via Ruby `super`). RBxxx_dispose dereferences DATA_PTR(self)+8 to call
    // the native scalar deleting destructor through the object's own vtable, before
    // any native destructor hook can run -- so for an already-freed (and possibly
    // heap-reused) native object this deref is itself the UAF. We intercept first.
    struct RubyDisposeGuardHooks {
        static RubyValue(__cdecl* orig_sprite)(RubyValue self);
        static RubyValue(__cdecl* orig_plane)(RubyValue self);
        static RubyValue(__cdecl* orig_window)(RubyValue self);

        static RubyValue __cdecl sprite_dispose_hook(RubyValue self) {
            if (neutralize_if_dead(self)) return ruby_nil;
            return orig_sprite(self);
        }
        static RubyValue __cdecl plane_dispose_hook(RubyValue self) {
            if (neutralize_if_dead(self)) return ruby_nil;
            return orig_plane(self);
        }
        static RubyValue __cdecl window_dispose_hook(RubyValue self) {
            if (neutralize_if_dead(self)) return ruby_nil;
            return orig_window(self);
        }
    };

    RubyValue(__cdecl* RubyDisposeGuardHooks::orig_sprite)(RubyValue) = nullptr;
    RubyValue(__cdecl* RubyDisposeGuardHooks::orig_plane)(RubyValue) = nullptr;
    RubyValue(__cdecl* RubyDisposeGuardHooks::orig_window)(RubyValue) = nullptr;

    void apply_sprite_dispose_fix() {
        // Enabled by default (safety fix); only skipped if explicitly set to false.
        auto config_value = mod_loader->get_config().get("sprite_dispose_fix");
        if (config_value && !config_value->get<bool>()) {
            mod_loader->log_info("SpriteDisposeFix disabled by config\n");
            return;
        }

        // Lifetime registry: base ctor (live) + base destroy (dead, after the body).
        mod_loader->hook_method(sprite_ctor_offset, &SpriteLifetimeHook::ctor_hook, &SpriteLifetimeHook::orig_ctor);
        mod_loader->hook_method(sprite_destroy_base_offset, &SpriteLifetimeHook::destroy_base_hook, &SpriteLifetimeHook::orig_destroy_base);

        // Double-destruction guard at the scalar deleting destructor.
        mod_loader->hook_method(sprite_scalar_dtor_offset, &SpriteLifetimeHook::scalar_dtor_hook, &SpriteLifetimeHook::orig_scalar_dtor);

        // Dead-container guard at the drawlist unlink. Covers BOTH callers
        // (destroy_base and set_ancestor), i.e. the direct and the deferred
        // (on-load) std::find crash on a disposed ancestor/viewport.
        mod_loader->hook_method(sprite_drawlist_remove_offset, &SpriteLifetimeHook::drawlist_remove_hook, &SpriteLifetimeHook::orig_drawlist_remove);

        // Ruby dispose gate: neutralize a dispose whose native object is already
        // dead before RBxxx_dispose dereferences the dangling native pointer.
        mod_loader->hook_function(rb_sprite_dispose_offset, &RubyDisposeGuardHooks::sprite_dispose_hook, &RubyDisposeGuardHooks::orig_sprite);
        mod_loader->hook_function(rb_plane_dispose_offset,  &RubyDisposeGuardHooks::plane_dispose_hook,  &RubyDisposeGuardHooks::orig_plane);
        mod_loader->hook_function(rb_window_dispose_offset, &RubyDisposeGuardHooks::window_dispose_hook, &RubyDisposeGuardHooks::orig_window);

        mod_loader->log_info("Applied SpriteDisposeFix (dead-container unlink guard + double-dispose UAF guard)\n");
    }
}
