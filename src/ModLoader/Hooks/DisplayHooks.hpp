#pragma once
#include <Windows.h>
namespace rm_modloader {
    void apply_display_hooks();
    // Final image rectangle in desktop coordinates, excluding letterbox bars.
    RECT display_output_bounds(HWND window);
}
