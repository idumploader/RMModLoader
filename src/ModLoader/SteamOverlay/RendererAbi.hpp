#pragma once
#include <cstddef>
#include <cstdint>

// Observed in Steam 11.12.30.7 (2026-10-13): present queries GetHWND,
// stores EAX, then calls vtable[8] without pushing any arguments and stores AL.
// That slot must return a capability bool with ret 0, not consume 17 args.
inline bool has_slot8_capability_query(const uint8_t* code, size_t size) {
    constexpr uint8_t pattern[] = {
        0xff,0x50,0x50,0x89,0x45,0,
        0x8b,0xcb,0x8b,0x03,0x8b,0x40,0x20,0xff,0xd0,0x88,0x45,0
    };
    for (size_t i=0; i+sizeof(pattern)<=size; ++i) {
        bool match=true;
        for (size_t j=0; j<sizeof(pattern); ++j) {
            if (j!=5 && j!=17 && code[i+j]!=pattern[j]) { match=false; break; }
        }
        if (match) return true;
    }
    return false;
}
