#pragma once
#include <cstdint>

namespace rm_modloader::display {
    struct Rect { int x, y, width, height; };

    // Fit the final image, not the game's logical viewport. Integer arithmetic
    // keeps the two bars within one pixel of each other at odd window sizes.
    inline Rect fit(int width, int height, int source_width, int source_height, bool preserve_aspect = true) {
        if (width <= 0 || height <= 0 || source_width <= 0 || source_height <= 0)
            return {0, 0, 0, 0};
        if (!preserve_aspect) return {0, 0, width, height};
        int w = width, h = height;
        if (int64_t(width) * source_height > int64_t(height) * source_width)
            w = int(int64_t(height) * source_width / source_height);
        else
            h = int(int64_t(width) * source_height / source_width);
        return {(width - w) / 2, (height - h) / 2, w, h};
    }
}
