#pragma once
#include "FakeRenderer.hpp"
#include <string>
#include <vector>

struct RendererMethodInfo {
    uintptr_t address = 0;
    unsigned argument_bytes = 0;
    bool short_getter = false;
    bool chrome_sync = false;
    bool deletes_texture = false;
    bool gets_hwnd = false;
    bool output_bounds = false;
    bool class_name = false;
    bool frame_info = false;
    bool returns_one = false;
    bool renderer_kind = false;
};
// Separate classification lets tests reorder methods without changing code.
bool classify_renderer_methods(const std::vector<RendererMethodInfo>& methods,
                               VtableLayout& layout, std::string& error);
bool discover_renderer_layout(HMODULE module, VtableLayout& layout, std::string& error);
