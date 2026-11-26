#include "HookRegistry.hpp"
#include "Logger.hpp"
#include <Windows.h>
#include <minhook.h>
#include <array>
#include <cstring>
#include <format>
#include <string>
#include <utility>

namespace rm_modloader {
    // Diagnostics must never interrupt a MinHook rollback or recovery halfway.
    template<typename... Args>
    static void log_hook_error(std::format_string<Args...> pattern, Args&&... args) noexcept {
        try {
            Logger::error(std::format(pattern, std::forward<Args>(args)...));
        } catch (...) {
            try { Logger::error("Hook registry recovery error (diagnostic unavailable)\n"); }
            catch (...) {}
        }
    }

    // Allocate both bookkeeping entries before changing any caller-owned slot.
    HookRegistry::PatchID HookRegistry::append_to_chain(HookChain& chain, void* detour, void** original, void* target) {
        const PatchID id = last_patch_id_;
        chain.entries.push_back({ id, detour, original });
        try {
            patch_targets_.emplace(id, target);
        } catch (...) {
            chain.entries.pop_back();
            throw;
        }
        *chain.entries[chain.entries.size() - 2].orig_slot = detour;
        *original = chain.trampoline;
        ++last_patch_id_;
        return id;
    }

    HookRegistry::PatchID HookRegistry::create_locked(void* target, void* detour, void** original) {
        if (!target || !detour || !original) return invalid_id;
        if (auto it = hook_chains_.find(target); it != hook_chains_.end()) {
            return append_to_chain(it->second, detour, original, target);
        }

        const PatchID id = last_patch_id_;
        auto cit = hook_chains_.try_emplace(target).first;
        HookChain& chain = cit->second;
        try {
            chain.entries.push_back({ id, detour, original });
            patch_targets_.emplace(id, target);
        } catch (...) {
            hook_chains_.erase(cit);
            throw;
        }
        const auto created = MH_CreateHook(target, detour, &chain.trampoline);
        if (created != MH_OK) {
            patch_targets_.erase(id);
            hook_chains_.erase(cit);
            log_hook_error("hook_function: MH_CreateHook failed for {} (status {})\n", target, static_cast<int>(created));
            return invalid_id;
        }

        // Publish the original before enabling: another thread may enter the
        // detour as soon as MinHook installs its jump. Restore it on rollback.
        // MinHook output slots need not contain an initialized pointer yet.
        std::array<unsigned char, sizeof(void*)> previous_original;
        std::memcpy(previous_original.data(), original, sizeof(void*));
        *original = chain.trampoline;
        const auto enabled = MH_EnableHook(target);
        if (enabled != MH_OK && enabled != MH_ERROR_ENABLED) {
            const auto removed = MH_RemoveHook(target);
            if (removed == MH_OK || removed == MH_ERROR_NOT_CREATED || removed == MH_ERROR_NOT_INITIALIZED) {
                std::memcpy(original, previous_original.data(), sizeof(void*));
                patch_targets_.erase(id);
                hook_chains_.erase(cit);
                log_hook_error("hook_function: MH_EnableHook failed for {} (status {})\n", target, static_cast<int>(enabled));
                return invalid_id;
            }
            // Keep the ID/trampoline owned if rollback itself failed; returning
            // invalid_id would strand the MinHook without any cleanup handle.
            ++last_patch_id_;
            log_hook_error("hook_function: enable failed for {}, rollback failed (statuses {}, {}); hook retained for cleanup\n",
                target, static_cast<int>(enabled), static_cast<int>(removed));
            return id;
        }
        ++last_patch_id_;
        return id;
    }

    HookRegistry::PatchID HookRegistry::create(void* target, void* detour, void** original) {
        std::lock_guard lock(mutex_);
        return create_locked(target, detour, original);
    }

    HookRegistry::PatchID HookRegistry::create_api(std::wstring_view library, std::string_view function, void* detour, void** original) {
        std::lock_guard lock(mutex_);
        // Same export resolution as MH_CreateHookApiEx, with shared chain setup.
        HMODULE module = GetModuleHandleW(std::wstring(library).c_str());
        void* target = module ? reinterpret_cast<void*>(GetProcAddress(module, std::string(function).c_str())) : nullptr;
        if (!target) {
            log_hook_error("hook_api_function: export unavailable for {}\n", function);
            return invalid_id;
        }
        return create_locked(target, detour, original);
    }

    // Only use after MinHook has removed the target (and freed its trampoline).
    void HookRegistry::forget_chain(void* target, HookChain& chain) {
        for (const auto& entry : chain.entries) {
            *entry.orig_slot = target;
            patch_targets_.erase(entry.id);
        }
        chain.trampoline = nullptr;
        chain.entries.clear();
    }

    void HookRegistry::remove(PatchID id) {
        if (id == invalid_id) return;
        std::lock_guard lock(mutex_);
        auto pit = patch_targets_.find(id);
        if (pit == patch_targets_.end()) {
            Logger::warning(std::format("unhook: unknown patch id {}\n", id));
            return;
        }
        void* target = pit->second;
        auto cit = hook_chains_.find(target);
        if (cit == hook_chains_.end()) return;
        HookChain& chain = cit->second;
        auto& entries = chain.entries;
        size_t index = 0;
        while (index < entries.size() && entries[index].id != id) ++index;
        if (index == entries.size()) return;

        if (entries.size() == 1 || index == 0) {
            // MH_RemoveHook disables an enabled hook itself. If it fails, the
            // trampoline is still owned by MinHook and our bookkeeping stays.
            const auto removed = MH_RemoveHook(target);
            if (removed != MH_OK && removed != MH_ERROR_NOT_CREATED && removed != MH_ERROR_NOT_INITIALIZED) {
                log_hook_error("unhook: MH_RemoveHook failed for {} (status {})\n", target, static_cast<int>(removed));
                return;
            }
            if (entries.size() == 1 || removed != MH_OK) {
                forget_chain(target, chain);
                hook_chains_.erase(cit);
                return;
            }

            // The old trampoline is freed. Publish no dangling slots while
            // rebuilding or restoring the head; keep non-tail chain links.
            chain.trampoline = nullptr;
            *entries.back().orig_slot = target;
            void* replacement = nullptr;
            const auto created = MH_CreateHook(target, entries[1].detour, &replacement);
            if (created == MH_OK) {
                chain.trampoline = replacement;
                *entries.back().orig_slot = replacement;
                const auto enabled = MH_EnableHook(target);
                if (enabled == MH_OK || enabled == MH_ERROR_ENABLED) {
                    *entries.front().orig_slot = target;
                    entries.erase(entries.begin());
                    patch_targets_.erase(id);
                    return;
                }
                const auto rollback_remove = MH_RemoveHook(target);
                if (rollback_remove != MH_OK && rollback_remove != MH_ERROR_NOT_CREATED && rollback_remove != MH_ERROR_NOT_INITIALIZED) {
                    // The replacement hook still exists. Commit its chain so a
                    // later remove/clear can clean it instead of losing ownership.
                    *entries.front().orig_slot = target;
                    entries.erase(entries.begin());
                    patch_targets_.erase(id);
                    log_hook_error("unhook: replacement enable/rollback failed for {} (statuses {}, {}); chain retained for cleanup\n",
                        target, static_cast<int>(enabled), static_cast<int>(rollback_remove));
                    return;
                }
                chain.trampoline = nullptr;
                *entries.back().orig_slot = target;
                log_hook_error("unhook: replacement enable failed for {} (status {}); restoring old head\n", target, static_cast<int>(enabled));
            } else {
                log_hook_error("unhook: replacement create failed for {} (status {}); restoring old head\n", target, static_cast<int>(created));
            }

            const auto restored = MH_CreateHook(target, entries.front().detour, &replacement);
            if (restored == MH_OK) {
                chain.trampoline = replacement;
                *entries.back().orig_slot = replacement;
                const auto enabled = MH_EnableHook(target);
                if (enabled == MH_OK || enabled == MH_ERROR_ENABLED) return;
                const auto rollback_remove = MH_RemoveHook(target);
                if (rollback_remove != MH_OK && rollback_remove != MH_ERROR_NOT_CREATED && rollback_remove != MH_ERROR_NOT_INITIALIZED) {
                    log_hook_error("unhook: restored enable/rollback failed for {}; old chain retained for cleanup\n", target);
                    return;
                }
            }
            // Both attempts failed and no MinHook remains. All exposed slots
            // must point at the live target, never a freed trampoline.
            forget_chain(target, chain);
            hook_chains_.erase(cit);
            log_hook_error("unhook: head recovery failed for {}; chain cleared\n", target);
            return;
        }

        void* next = index + 1 < entries.size() ? entries[index + 1].detour : chain.trampoline;
        *entries[index - 1].orig_slot = next;
        *entries[index].orig_slot = target;
        entries.erase(entries.begin() + index);
        patch_targets_.erase(id);
    }

    void HookRegistry::clear() {
        std::lock_guard lock(mutex_);
        for (auto it = hook_chains_.begin(); it != hook_chains_.end();) {
            const auto removed = MH_RemoveHook(it->first);
            if (removed == MH_OK || removed == MH_ERROR_NOT_CREATED || removed == MH_ERROR_NOT_INITIALIZED) {
                forget_chain(it->first, it->second);
                it = hook_chains_.erase(it);
            } else {
                log_hook_error("clear_hooks: MH_RemoveHook failed for {} (status {}); retained for retry\n", it->first, static_cast<int>(removed));
                ++it;
            }
        }
    }
}
