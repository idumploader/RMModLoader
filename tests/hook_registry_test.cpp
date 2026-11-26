#include "../src/ModLoader/HookRegistry.hpp"
#include "../src/ModLoader/Logger.hpp"
#include <Windows.h>
#include <minhook.h>
#include <cassert>
#include <crtdbg.h>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <vector>

// Fail one registry allocation, then allow error reporting and cleanup to run.
static int fail_allocation_after = -1;
void* operator new(size_t size) {
    if (fail_allocation_after == 0) {
        fail_allocation_after = -1;
        throw std::bad_alloc();
    }
    if (fail_allocation_after > 0) --fail_allocation_after;
    if (void* memory = std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, size_t) noexcept { std::free(memory); }

namespace rm_modloader {
    static int registry_errors, retained_errors, cleared_errors;
    static bool fail_error_logging;
    void Logger::error(std::string_view message) {
        if (fail_error_logging) throw std::bad_alloc();
        ++registry_errors;
        if (message.find("retained for cleanup") != message.npos) ++retained_errors;
        if (message.find("chain cleared") != message.npos) ++cleared_errors;
    }
    void Logger::warning(std::string_view) {}
}
using Function = int (__cdecl*)(int);
__declspec(noinline) int __cdecl original(int value) {
    volatile int offset = 1;
    return value + offset;
}
Function next_first, next_second, next_third;
int __cdecl first(int value) { return next_first(value) + 10; }
int __cdecl second(int value) { return next_second(value) + 100; }
int __cdecl third(int value) { return next_third(value) + 1000; }
using ProcessIdFunction = DWORD (WINAPI*)();
ProcessIdFunction next_process_id_first, next_process_id_second;
DWORD WINAPI process_id_first() { return next_process_id_first() + 1; }
DWORD WINAPI process_id_second() { return next_process_id_second() + 10; }

#ifndef HOOK_REGISTRY_STUB
int main() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
    std::puts("Initialize"); std::fflush(stdout);
    const auto initialized = MH_Initialize();
    std::printf("MinHook initialize: %d\n", initialized); std::fflush(stdout);
    assert(initialized == MH_OK);
    rm_modloader::HookRegistry registry;
    Function volatile call = original; // Invoke patched code, never constant-fold.
    auto add = [&](Function detour, Function& next) {
        return registry.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(detour),
                               reinterpret_cast<void**>(&next));
    };
    std::printf("Original result: %d\n", call(4)); std::fflush(stdout);
    assert(call(4) == 5);
    Function untouched = original;
    assert(registry.create(nullptr, reinterpret_cast<void*>(first), reinterpret_cast<void**>(&untouched)) == registry.invalid_id);
    assert(registry.create(reinterpret_cast<void*>(original), nullptr, reinterpret_cast<void**>(&untouched)) == registry.invalid_id);
    assert(registry.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(first), nullptr) == registry.invalid_id);
    assert(registry.create_api(L"missing-hook-registry-module.dll", "missing", reinterpret_cast<void*>(first), reinterpret_cast<void**>(&untouched)) == registry.invalid_id);
    assert(untouched == original);
    auto a = add(first, next_first);
    std::printf("First hook ID: %lld\n", a); std::fflush(stdout);
    auto b = add(second, next_second);
    std::printf("Second hook ID: %lld\n", b); std::fflush(stdout);
    auto c = add(third, next_third);
    std::puts("Three hooks installed"); std::fflush(stdout);
    assert(a != registry.invalid_id && b != registry.invalid_id && c != registry.invalid_id);
    assert(call(4) == 1115);
    registry.remove(b); // Middle removal bypasses it without recreating trampoline.
    std::puts("Middle removed"); std::fflush(stdout);
    assert(call(4) == 1015);
    registry.remove(a); // Head removal must reconnect tail to a new trampoline.
    std::puts("Head removed"); std::fflush(stdout);
    assert(call(4) == 1005);
    registry.remove(c);
    assert(call(4) == 5);
    a = add(first, next_first);
    b = add(second, next_second);
    c = add(third, next_third);
    registry.remove(c); // Tail removal reconnects second directly to original.
    assert(call(4) == 115);
    registry.clear();
    assert(call(4) == 5);
    assert(next_first == original && next_second == original);
    registry.clear(); // Idempotent shutdown.
    registry.remove(registry.invalid_id);
    a = add(first, next_first);
    assert(call(4) == 15);
    registry.clear();
    assert(call(4) == 5);

    // Allocation failure must not install an untracked hook or rewrite slots.
    int creation_failures = 0, append_failures = 0;
    for (int failure = 0; failure < 6; ++failure) {
        rm_modloader::HookRegistry fresh;
        next_first = original;
        fail_allocation_after = failure;
        try {
            a = fresh.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(first), reinterpret_cast<void**>(&next_first));
            fail_allocation_after = -1;
            assert(a != fresh.invalid_id && call(4) == 15);
        } catch (const std::bad_alloc&) {
            fail_allocation_after = -1;
            ++creation_failures;
            assert(next_first == original && call(4) == 5);
            a = fresh.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(first), reinterpret_cast<void**>(&next_first));
            assert(a != fresh.invalid_id && call(4) == 15);
        }
        fresh.clear();
        assert(call(4) == 5);
    }
    for (int failure = 0; failure < 4; ++failure) {
        rm_modloader::HookRegistry fresh;
        a = fresh.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(first), reinterpret_cast<void**>(&next_first));
        Function previous_first = next_first;
        next_second = original;
        fail_allocation_after = failure;
        try {
            b = fresh.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(second), reinterpret_cast<void**>(&next_second));
            fail_allocation_after = -1;
            assert(b != fresh.invalid_id && call(4) == 115);
        } catch (const std::bad_alloc&) {
            fail_allocation_after = -1;
            ++append_failures;
            assert(next_first == previous_first && next_second == original && call(4) == 15);
            b = fresh.create(reinterpret_cast<void*>(original), reinterpret_cast<void*>(second), reinterpret_cast<void**>(&next_second));
            assert(b != fresh.invalid_id && call(4) == 115);
        }
        fresh.clear();
        assert(call(4) == 5);
    }
    assert(creation_failures > 0 && append_failures > 0);
    // API and raw-target calls must resolve to the same registry chain.
    void* process_id_target = reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "GetCurrentProcessId"));
    assert(process_id_target);
    ProcessIdFunction volatile process_id_call = reinterpret_cast<ProcessIdFunction>(process_id_target);
    DWORD process_id = process_id_call();
    a = registry.create_api(L"kernel32.dll", "GetCurrentProcessId", reinterpret_cast<void*>(process_id_first),
                            reinterpret_cast<void**>(&next_process_id_first));
    b = registry.create(process_id_target, reinterpret_cast<void*>(process_id_second),
                        reinterpret_cast<void**>(&next_process_id_second));
    assert(a != registry.invalid_id && b != registry.invalid_id);
    assert(process_id_call() == process_id + 11);
    registry.remove(a);
    assert(process_id_call() == process_id + 10);
    registry.clear();
    assert(process_id_call() == process_id);
    assert(MH_Uninitialize() == MH_OK);
    next_first = original;
    assert(add(first, next_first) == registry.invalid_id && next_first == original);
    std::puts("Hook registry PASS");
}
#endif
#ifdef HOOK_REGISTRY_STUB
namespace {
    void* fake_target = nullptr;
    void* fake_detour = nullptr;
    void* fake_trampoline = nullptr;
    bool fake_enabled = false;
    uintptr_t trampoline_counter = 0x7000;
    std::vector<MH_STATUS> create_results, enable_results, remove_results;
    MH_STATUS result(std::vector<MH_STATUS>& plan) {
        if (plan.empty()) return MH_OK;
        auto first = plan.front(); plan.erase(plan.begin()); return first;
    }
    void reset_fake() {
        assert(!fake_target);
        create_results.clear(); enable_results.clear(); remove_results.clear();
    }
}
extern "C" MH_STATUS WINAPI MH_CreateHook(LPVOID target, LPVOID detour, LPVOID* original_slot) {
    auto status = result(create_results);
    if (status != MH_OK) return status;
    if (fake_target) return MH_ERROR_ALREADY_CREATED;
    fake_target = target; fake_detour = detour;
    fake_trampoline = reinterpret_cast<void*>(++trampoline_counter);
    fake_enabled = false;
    *original_slot = fake_trampoline;
    return MH_OK;
}
extern "C" MH_STATUS WINAPI MH_EnableHook(LPVOID target) {
    auto status = result(enable_results);
    if (status != MH_OK) return status;
    assert(target == fake_target);
    fake_enabled = true;
    return MH_OK;
}
extern "C" MH_STATUS WINAPI MH_RemoveHook(LPVOID target) {
    auto status = result(remove_results);
    if (status != MH_OK) return status;
    if (target != fake_target) return MH_ERROR_NOT_CREATED;
    fake_target = fake_detour = fake_trampoline = nullptr;
    fake_enabled = false;
    return MH_OK;
}
int main() {
    using rm_modloader::HookRegistry;
    void* target = reinterpret_cast<void*>(original);
    void* d1 = reinterpret_cast<void*>(first);
    void* d2 = reinterpret_cast<void*>(second);
    void* d3 = reinterpret_cast<void*>(third);
    void* o1 = target;
    void* o2 = target;
    void* o3 = target;
    auto add = [&](HookRegistry& registry, void* detour, void*& slot) {
        return registry.create(target, detour, &slot);
    };
    reset_fake();
    {
        HookRegistry registry;
        create_results = {MH_ERROR_UNSUPPORTED_FUNCTION};
        assert(add(registry, d1, o1) == registry.invalid_id);
        assert(!fake_target && o1 == target);
        enable_results = {MH_ERROR_MEMORY_PROTECT};
        assert(add(registry, d1, o1) == registry.invalid_id);
        assert(!fake_target && o1 == target);
        enable_results = {MH_ERROR_MEMORY_PROTECT};
        remove_results = {MH_ERROR_MEMORY_PROTECT};
        auto retained = add(registry, d1, o1);
        assert(retained != registry.invalid_id && fake_target && o1 == fake_trampoline);
        registry.clear(); assert(!fake_target && o1 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        auto before = o1;
        remove_results = {MH_ERROR_MEMORY_PROTECT};
        registry.remove(a);
        assert(fake_target && o1 == before);
        registry.remove(a); assert(!fake_target && o1 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        auto b = add(registry, d2, o2);
        auto c = add(registry, d3, o3);
        auto old_trampoline = o3;
        create_results = {MH_ERROR_MEMORY_ALLOC, MH_OK};
        registry.remove(a);
        assert(fake_enabled && fake_detour == d1);
        assert(o1 == d2 && o2 == d3 && o3 == fake_trampoline && o3 != old_trampoline);
        registry.remove(a); // The failed removal retained its original ID.
        assert(fake_detour == d2 && o1 == target && o2 == d3 && o3 == fake_trampoline);
        registry.remove(b); registry.remove(c); assert(!fake_target && o2 == target && o3 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        auto b = add(registry, d2, o2);
        create_results = {MH_ERROR_MEMORY_ALLOC, MH_ERROR_MEMORY_ALLOC};
        registry.remove(a);
        assert(!fake_target && o1 == target && o2 == target);
        auto fresh = add(registry, d3, o3);
        registry.remove(a); registry.remove(b); // Forgotten IDs cannot remove a new chain.
        assert(fake_target && fake_detour == d3);
        registry.remove(fresh); assert(!fake_target && o3 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        add(registry, d2, o2);
        enable_results = {MH_ERROR_MEMORY_PROTECT, MH_OK};
        registry.remove(a);
        assert(fake_enabled && fake_detour == d1 && o1 == d2 && o2 == fake_trampoline);
        registry.clear(); assert(!fake_target && o1 == target && o2 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        auto b = add(registry, d2, o2);
        enable_results = {MH_ERROR_MEMORY_PROTECT};
        remove_results = {MH_OK, MH_ERROR_MEMORY_PROTECT};
        registry.remove(a);
        assert(fake_detour == d2 && o1 == target && o2 == fake_trampoline);
        registry.remove(b); assert(!fake_target && o2 == target);
    }
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        add(registry, d2, o2);
        enable_results = {MH_ERROR_MEMORY_PROTECT, MH_ERROR_MEMORY_PROTECT};
        registry.remove(a);
        assert(!fake_target && o1 == target && o2 == target);
        add(registry, d1, o1);
        remove_results = {MH_ERROR_MEMORY_PROTECT};
        registry.clear(); assert(fake_target && o1 == fake_trampoline);
        registry.clear(); assert(!fake_target && o1 == target);
    }
    assert(rm_modloader::registry_errors >= 8);
    assert(rm_modloader::retained_errors >= 2 && rm_modloader::cleared_errors >= 2);
    reset_fake();
    {
        HookRegistry registry;
        auto a = add(registry, d1, o1);
        add(registry, d2, o2);
        create_results = {MH_ERROR_MEMORY_ALLOC, MH_OK};
        rm_modloader::fail_error_logging = true;
        registry.remove(a); // Reporting failure must not interrupt rollback.
        rm_modloader::fail_error_logging = false;
        assert(fake_enabled && fake_detour == d1 && o1 == d2 && o2 == fake_trampoline);
        registry.clear(); assert(!fake_target && o1 == target && o2 == target);
    }
    std::puts("Hook registry forced failure PASS");
}
#endif
