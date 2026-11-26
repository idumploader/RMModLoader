#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace rm_modloader {
// Pure pixel kernel. Source/output must not overlap; stride is in uint32 pixels.
// Caller validates w,h >= 3 and bands >= 1. run(bands, job) must complete every
// job and join before returning. No RGSS, Ruby, global buffers or engine calls.
// RGSS-compatible edge replication and one final division (no intermediate loss).
template<class Run>
void blur_rgss_box_3x3(const uint32_t* source, int stride, int w, int h,
                     uint32_t* output, int bands, Run&& run) {
    // Allocate all scratch before dispatch: allocation failure cannot escape
    // a worker thread or leave a partially modified engine bitmap.
    std::vector<uint64_t> scratch(size_t(bands) * 3 * w);
    const auto expand = [](uint32_t p) -> uint64_t {
        return (p & 0xffu) | (uint64_t((p >> 8) & 0xffu) << 16) |
            (uint64_t((p >> 16) & 0xffu) << 32) | (uint64_t(p >> 24) << 48);
    };
    // One job per independent row band, including its own clamped halo.
    run(bands, [&](int band) {
        const int first = int(int64_t(h) * band / bands);
        const int end = int(int64_t(h) * (band + 1) / bands);
        auto* rows = scratch.data() + size_t(band) * 3 * w;
        auto horizontal = [&](int y, uint64_t* row) {
            const auto* in = source + ptrdiff_t((std::clamp)(y, 0, h - 1)) * stride;
            uint64_t left = expand(in[0]), middle = left, right = expand(in[1]);
            for (int x = 0; x < w; ++x) {
                row[x] = left + middle + right;
                left = middle; middle = right;
                right = expand(in[(std::min)(x + 2, w - 1)]);
            }
        };
        horizontal(first - 1, rows);
        horizontal(first, rows + w);
        horizontal(first + 1, rows + 2 * w);
        int top = 0, center = 1, bottom = 2;
        for (int y = first; y < end; ++y) {
            auto* out = output + size_t(y) * w;
            for (int x = 0; x < w; ++x) {
                const uint64_t sum = rows[size_t(top) * w + x] +
                    rows[size_t(center) * w + x] + rows[size_t(bottom) * w + x];
                out[x] = uint32_t((sum & 0xffffu) / 9) |
                    (uint32_t(((sum >> 16) & 0xffffu) / 9) << 8) |
                    (uint32_t(((sum >> 32) & 0xffffu) / 9) << 16) |
                    (uint32_t((sum >> 48) / 9) << 24);
            }
            if (y + 1 < end) {
                const int recycled = top; top = center; center = bottom; bottom = recycled;
                horizontal(y + 2, rows + size_t(bottom) * w);
            }
        }
    });
}
}
