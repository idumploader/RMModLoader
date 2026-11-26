#define NOMINMAX
#include "GlyphCacheHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMGlobal.hpp"
#include "../Hook.hpp"
#include <Windows.h>
#include <array>
#include <cstring>
#include <list>
#include <unordered_map>
#include <vector>
#include <intrin.h>

namespace rm_modloader {
namespace {
    // Only RGSS's text measurement/drawing import is replaced. The worker never
    // enters this cache; other threads and unsupported GDI requests pass through.
    decltype(&GetGlyphOutlineW) original_glyph = nullptr;
    DWORD owner = 0;
    bool enabled = true;
    size_t limit = 8 * 1024 * 1024;
    constexpr size_t max_entries = 4096, max_fonts = 128;
    std::array<LOGFONTW, max_fonts> fonts{};
    size_t font_count = 0;
    HDC prepared_dc = nullptr;
    unsigned prepared_font = 0;
    bool prepared = false;
    uint64_t prepare_calls = 0;
    int last_map_mode = 0, last_graphics_mode = 0;
    uintptr_t last_caller = 0;
    uint64_t calls = 0, hits = 0, misses = 0, fills = 0, evictions = 0, bypasses = 0;
    size_t charged = 0, payload = 0, peak = 0;

    struct Key {
        unsigned font, character, format;
        MAT2 matrix;
        bool operator==(const Key& other) const {
            return font == other.font && character == other.character && format == other.format &&
                std::memcmp(&matrix, &other.matrix, sizeof(matrix)) == 0;
        }
    };
    struct Hash {
        size_t operator()(const Key& key) const {
            size_t h = key.font * 16777619u ^ key.character;
            h = h * 16777619u ^ key.format;
            const auto* bytes = reinterpret_cast<const unsigned char*>(&key.matrix);
            for (size_t i = 0; i < sizeof(key.matrix); ++i) h = h * 16777619u ^ bytes[i];
            return h;
        }
    };
    struct Entry {
        Key key;
        GLYPHMETRICS metrics;
        DWORD result;
        bool raster_ready;
        std::vector<unsigned char> raster;
    };
    using List = std::list<Entry>;
    List entries;
    std::unordered_map<Key, List::iterator, Hash> index;

    // Payload capacity plus object/node sizes and a conservative node allowance.
    // Allocator bookkeeping is implementation-dependent and reported separately.
    constexpr size_t node_charge = sizeof(Entry) + sizeof(std::pair<const Key, List::iterator>) + 64;
    size_t owned_bytes() {
        return charged + index.bucket_count() * sizeof(void*) + sizeof(fonts);
    }
    void clear() {
        index.clear();
        decltype(index){}.swap(index);
        entries.clear();
        charged = payload = font_count = 0;
        prepared = false;
        prepared_dc = nullptr;
    }
    void reset_stats() {
        calls = hits = misses = fills = evictions = bypasses = 0;
        prepare_calls = 0;
        peak = owned_bytes();
    }
    void evict_one() {
        const auto& last = entries.back();
        charged -= node_charge + last.raster.capacity();
        payload -= last.raster.capacity();
        index.erase(last.key);
        entries.pop_back();
        ++evictions;
    }
    bool room(size_t bytes) {
        while (!entries.empty() && (owned_bytes() + bytes > limit || entries.size() >= max_entries))
            evict_one();
        return owned_bytes() + bytes <= limit;
    }
    void prepare_font(HDC dc) {
        if (GetCurrentThreadId() != owner) return;
        ++prepare_calls;
        prepared = false;
        if (!enabled || !dc || GetCurrentThreadId() != owner) return;
        LOGFONTW font{};
        auto handle = GetCurrentObject(dc, OBJ_FONT);
        if (!handle || GetObjectW(handle, sizeof(font), &font) != sizeof(font)) return;
        // RGSS creates MM_TEXT screen-compatible DCs. More general coordinate
        // transforms require a richer key and are deliberately not cached.
        last_map_mode = GetMapMode(dc);
        last_graphics_mode = GetGraphicsMode(dc);
        if (last_map_mode != MM_TEXT || last_graphics_mode != GM_COMPATIBLE) return;
        if (index.bucket_count() < max_entries) index.reserve(max_entries);
        size_t id = 0;
        while (id < font_count && std::memcmp(&fonts[id], &font, sizeof(font)) != 0) ++id;
        if (id == font_count) {
            if (font_count == max_fonts) { clear(); id = 0; }
            fonts[font_count++] = font;
        }
        prepared_dc = dc;
        prepared_font = static_cast<unsigned>(id);
        prepared = true;
    }
    struct FontContext {
        static HDC (__thiscall FontContext::* original_dc)();
        HDC __thiscall dc_hook() {
            HDC dc = (this->*original_dc)();
            try { prepare_font(dc); }
            catch (...) { enabled = false; clear(); }
            return dc;
        }
    };
    HDC (__thiscall FontContext::* FontContext::original_dc)() = nullptr;

    DWORD WINAPI glyph_hook(HDC dc, UINT character, UINT format, LPGLYPHMETRICS metrics,
                            DWORD bytes, LPVOID buffer, const MAT2* matrix) {
        if (GetCurrentThreadId() != owner)
            return original_glyph(dc, character, format, metrics, bytes, buffer, matrix);
        const auto caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - reinterpret_cast<uintptr_t>(rgss_module);
        last_caller = caller;
        if (!enabled || !prepared || GetCurrentThreadId() != owner || dc != prepared_dc ||
            caller < 0x1f150 || caller >= 0x1f9a0 || !metrics || !matrix ||
            (format != GGO_METRICS && format != GGO_GRAY8_BITMAP) ||
            (buffer && bytes == 0)) {
            return original_glyph(dc, character, format, metrics, bytes, buffer, matrix);
        }
        ++calls;
        const Key key{prepared_font, character, format, *matrix};
        try {
            auto found = index.find(key);
            if (found != index.end()) {
                auto it = found->second;
                // Short-buffer errors and their metrics/last-error behavior stay
                // with GDI. A size-only query can use a metrics-only entry.
                if (!buffer || (bytes >= it->result && it->raster_ready)) {
                    *metrics = it->metrics;
                    if (buffer && it->result) std::memcpy(buffer, it->raster.data(), it->result);
                    const DWORD result = it->result;
                    entries.splice(entries.begin(), entries, it);
                    ++hits;
                    return result;
                }
                ++bypasses;
                const DWORD result = original_glyph(dc, character, format, metrics, bytes, buffer, matrix);
                if (result != GDI_ERROR && result == it->result && bytes >= result && !it->raster_ready) {
                    // Move this entry aside while evicting others to make room.
                    Entry next = std::move(*it);
                    charged -= node_charge + next.raster.capacity();
                    payload -= next.raster.capacity();
                    entries.erase(it);
                    index.erase(found);
                    next.metrics = *metrics;
                    if (!room(node_charge + result)) return result;
                    next.raster.assign(static_cast<unsigned char*>(buffer), static_cast<unsigned char*>(buffer) + result);
                    next.raster_ready = true;
                    if (room(node_charge + next.raster.capacity())) {
                        charged += node_charge + next.raster.capacity();
                        payload += next.raster.capacity();
                        entries.push_front(std::move(next));
                        index.emplace(key, entries.begin());
                        ++fills;
                    }
                    peak = (std::max)(peak, owned_bytes());
                }
                return result;
            }
            ++misses;
            const DWORD result = original_glyph(dc, character, format, metrics, bytes, buffer, matrix);
            if (result == GDI_ERROR || result > limit || (buffer && bytes < result)) return result;
            if (!room(node_charge + (buffer ? result : 0))) return result;
            Entry next{key, *metrics, result, result == 0, {}};
            if (buffer && result) {
                next.raster.assign(static_cast<unsigned char*>(buffer), static_cast<unsigned char*>(buffer) + result);
                next.raster_ready = true;
            }
            if (room(node_charge + next.raster.capacity())) {
                charged += node_charge + next.raster.capacity();
                payload += next.raster.capacity();
                entries.push_front(std::move(next));
                index.emplace(key, entries.begin());
            }
            peak = (std::max)(peak, owned_bytes());
            return result;
        } catch (...) {
            // GDI/Ruby must never receive a C++ allocation exception.
            enabled = false;
            clear();
            return original_glyph(dc, character, format, metrics, bytes, buffer, matrix);
        }
    }
    RubyValue __cdecl enable_api(RubyValue, RubyValue value) {
        if (value != ruby_true && value != ruby_false) return ruby_false;
        enabled = value == ruby_true;
        if (!enabled) clear();
        return ruby_true;
    }
    RubyValue __cdecl clear_api(RubyValue) { clear(); reset_stats(); return ruby_true; }
    RubyValue __cdecl limit_api(RubyValue, RubyValue value) {
        const int mib = rb_parse_int(value);
        if (mib < 1 || mib > 32) return ruby_false;
        limit = size_t(mib) * 1024 * 1024;
        while (!entries.empty() && owned_bytes() > limit) evict_one();
        return ruby_true;
    }
    RubyValue __cdecl status_api(RubyValue) {
        const auto text = nlohmann::json{{"enabled",enabled},{"limit_bytes",limit},
            {"owned_bytes",owned_bytes()},{"payload_bytes",payload},{"peak_bytes",peak},
            {"entries",entries.size()},{"fonts",font_count},{"calls",calls},{"hits",hits},
            {"misses",misses},{"raster_fills",fills},{"evictions",evictions},{"bypasses",bypasses},
            {"max_entries",max_entries},{"allocator_overhead_included",false},
            {"prepare_calls",prepare_calls},{"prepared",prepared},{"owner_thread",owner},
            {"status_thread",GetCurrentThreadId()},{"map_mode",last_map_mode},
            {"graphics_mode",last_graphics_mode},{"last_caller",last_caller}}.dump();
        return rb_str_new(text.data(), static_cast<long>(text.size()));
    }
}
void finish_glyph_cache() { clear(); }
void apply_glyph_cache_hooks() {
    original_glyph = at_address<decltype(original_glyph)>(rgss_module, 0x1a2030);
    mod_loader->hook_method(0x19860, &FontContext::dc_hook, &FontContext::original_dc);
    mod_loader->patch_memory(0x1a2030, reinterpret_cast<uintptr_t>(&glyph_hook));
    mod_loader->add_postinit_handler([] {
        // Hook installation runs on the loader thread; RGSS/Ruby runs on a
        // different thread. Capture ownership when Ruby enters rgss_main.
        owner = GetCurrentThreadId();
        mod_loader->register_ruby_method("glyph_cache_enable", enable_api);
        mod_loader->register_ruby_method("glyph_cache_clear", clear_api);
        mod_loader->register_ruby_method("glyph_cache_limit_mib", limit_api);
        mod_loader->register_ruby_method("glyph_cache_status", status_api);
    });
}
}
