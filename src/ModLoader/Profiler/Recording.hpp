#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

namespace rm_modloader::profiler {
    enum EventKind : uint32_t {
        Call = 0x08, Return = 0x10, CCall = 0x20, CReturn = 0x40,
        Raise = 0x80, Frame = 0x100000
    };

    // QPC ticks, not CPU time. Method 0 represents an unresolved method.
    struct Event {
        uint64_t tick;
        uint32_t context;
        uint32_t method;
        uint32_t cfp;
        uint32_t kind;
    };

    struct MethodStats {
        uint64_t self = 0, total = 0, calls = 0, completed = 0;
        uint64_t unwound = 0, open_at_stop = 0;
    };
    struct FrameStats {
        uint64_t begin, end;
        bool partial;
    };
    struct Summary {
        std::vector<MethodStats> methods;
        std::vector<FrameStats> frames;
        uint64_t unattributed = 0, unmatched_returns = 0, raises = 0;
        uint64_t context_changes = 0;
    };

    // Offline replay: never runs in the VM callback. Only the observed active
    // Fiber accrues time. Switch boundaries are inferred from events, so the
    // interval up to the first event in a new Fiber belongs to the previous one.
    // This limitation is exposed in every report, alongside the raw events.
    inline Summary summarize(const std::vector<Event>& events, size_t method_count,
                             uint64_t begin, uint64_t end) {
        struct Activation { uint32_t method, cfp; bool native; };
        struct Context {
            std::vector<Activation> stack;
            std::map<uint32_t, size_t> active_methods;
            void pop() {
                const auto method = stack.back().method;
                if (--active_methods[method] == 0) active_methods.erase(method);
                stack.pop_back();
            }
        };
        std::map<uint32_t, Context> contexts;
        Summary out;
        out.methods.resize(method_count);
        uint32_t active = 0;
        uint64_t last = begin, frame_begin = begin;
        bool first_frame = true;

        auto charge = [&](uint64_t now) {
            if (now < last) now = last;
            auto& context = contexts[active];
            const auto& stack = context.stack;
            const auto delta = now - last;
            if (stack.empty()) out.unattributed += delta;
            else {
                out.methods[stack.back().method].self += delta;
                // Count a recursive method only once per interval in inclusive
                // totals. Otherwise one method can exceed the whole recording.
                for (const auto& [method, count] : context.active_methods)
                    out.methods[method].total += delta;
            }
            last = now;
        };

        for (const auto& event : events) {
            if (event.tick > end) break;
            charge(event.tick);
            if (event.context != active) {
                if (active) ++out.context_changes;
                active = event.context;
            }
            if (event.kind == Frame) {
                out.frames.push_back({frame_begin, event.tick, first_frame});
                frame_begin = event.tick;
                first_frame = false;
                continue;
            }
            if (event.kind == Raise) { ++out.raises; continue; }
            if (event.method >= method_count) continue;
            auto& context = contexts[active];
            auto& stack = context.stack;
            const bool native = event.kind == CCall || event.kind == CReturn;
            // RGSS emits C_CALL before pushing the 44-byte control frame,
            // C_RETURN normally after popping it. Non-local block exits can
            // emit C_RETURN while that native frame is still current.
            // Ruby CALL/RETURN always use their own frame.
            const auto frame = native && event.cfp >= 44 ? event.cfp - 44 : event.cfp;
            if (event.kind == Call || event.kind == CCall) {
                // A C exception may skip C_RETURN. Recover when execution has
                // demonstrably unwound to a shallower VM frame.
                while (!stack.empty() && stack.back().cfp < event.cfp) {
                    ++out.methods[stack.back().method].unwound;
                    context.pop();
                }
                stack.push_back({event.method, frame, native});
                ++context.active_methods[event.method];
                ++out.methods[event.method].calls;
            } else if (event.kind == Return || event.kind == CReturn) {
                auto matches_return = [&](const Activation& candidate) {
                    return candidate.method == event.method && candidate.native == native &&
                        (candidate.cfp == frame || (native && candidate.cfp == event.cfp));
                };
                size_t found = stack.size();
                while (found) {
                    const auto& candidate = stack[--found];
                    if (matches_return(candidate)) break;
                }
                if (stack.empty() || !matches_return(stack[found])) {
                    ++out.unmatched_returns;
                    continue;
                }
                while (stack.size() > found + 1) {
                    ++out.methods[stack.back().method].unwound;
                    context.pop();
                }
                ++out.methods[event.method].completed;
                context.pop();
            }
        }
        charge(end);
        if (end > frame_begin) out.frames.push_back({frame_begin, end, true});
        for (const auto& [id, context] : contexts)
            for (const auto& entry : context.stack) ++out.methods[entry.method].open_at_stop;
        return out;
    }
}
