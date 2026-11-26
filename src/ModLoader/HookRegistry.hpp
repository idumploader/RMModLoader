#pragma once
#include <cstdint>
#include <mutex>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace rm_modloader {
    // Owns MinHook chains and patch IDs. The caller-owned original function slots
    // must outlive their hooks; adding/removing neighbours rewrites those slots.
    class HookRegistry {
    public:
        using PatchID = int64_t;
        static constexpr PatchID invalid_id = -1;
        PatchID create(void* target, void* detour, void** original);
        PatchID create_api(std::wstring_view library, std::string_view function, void* detour, void** original);
        void remove(PatchID id);
        // Called while the RGSS module and MinHook are still available.
        void clear();

    private:
        struct HookEntry {
            PatchID id;
            void* detour;
            void** orig_slot;
        };
        struct HookChain {
            void* trampoline = nullptr;
            std::vector<HookEntry> entries;
        };
        PatchID append_to_chain(HookChain& chain, void* detour, void** original, void* target);
        PatchID create_locked(void* target, void* detour, void** original);
        void forget_chain(void* target, HookChain& chain);
        PatchID last_patch_id_ = 0;
        std::unordered_map<void*, HookChain> hook_chains_;
        std::unordered_map<PatchID, void*> patch_targets_;
        std::mutex mutex_;
    };
}
