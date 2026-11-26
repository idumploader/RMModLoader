#pragma once
#include "../RMClasses.hpp"
#include <memory>
#include <stdexcept>

namespace rm_modloader {

// RGSS301: resize_screen changes the Screen rect, but keeps the startup-only
// brightness (GameFrame+24C/250) and frozen-transition (254/258) surfaces.
// Prepare all allocations first; commit only after the native resize succeeds.
class HRFixScreenBuffers {
    using Destroy = void* (__thiscall*)(Surface*, char);
    struct Deleter {
        Destroy destroy;
        void operator()(Surface* value) const { if (value) destroy(value, 1); }
    };
    using Owned = std::unique_ptr<Surface, Deleter>;
    using SetSurface = Surface* (__thiscall*)(RxSprite*, Surface*, RECT*);
    GameFrame* game_;
    HMODULE module_;
    Owned canvas_, brightness_, transition_;

    template<class T> T function(unsigned offset) const {
        return reinterpret_cast<T>(reinterpret_cast<unsigned char*>(module_) + offset);
    }
    Owned allocate(Surface* previous, int width, int height) const {
        Owned result(nullptr, Deleter{function<Destroy>(0x10b280)});
        if (!previous || (previous->rect.right - previous->rect.left == width &&
                          previous->rect.bottom - previous->rect.top == height)) return result;
        const auto alloc = function<void* (__cdecl*)(unsigned)>(0x17e979);
        const auto construct = function<Surface* (__thiscall*)(Surface*, int)>(0x10b120);
        const auto init = function<int (__thiscall*)(Surface*, int, int)>(0x10b3b0);
        auto* memory = static_cast<Surface*>(alloc(sizeof(Surface)));
        if (!memory) throw std::bad_alloc();
        result.reset(construct(memory, 32));
        if (!init(result.get(), width, height))
            throw std::runtime_error("Could not allocate resized Screen buffers");
        return result;
    }
    void attach(Owned& replacement, Surface*& slot, RxSprite* sprite) {
        if (!replacement) return;
        auto* old = slot;
        slot = replacement.release();
        // Native setter updates source and destination rects and invalidates
        // derived bounds. It preserves opacity, visibility, blend mode and z.
        if (sprite) function<SetSurface>(0x1d180)(sprite, slot, nullptr);
        replacement.reset(old);
    }
public:
    HRFixScreenBuffers(GameFrame* game, HMODULE module, int width, int height)
        : game_(game), module_(module),
          canvas_(allocate(game->screen->surface, width, height)),
          brightness_(allocate(game->surface24C, width, height)),
          transition_(allocate(game->surface254, width, height)) {}

    void commit() {
        attach(canvas_, game_->screen->surface, nullptr);
        attach(brightness_, game_->surface24C, game_->sprite250);
        attach(transition_, game_->surface254, game_->sprite258);
    }
};
}
