#include "../src/ModLoader/Profiler/Recording.hpp"
#include <cassert>
#include <iostream>

using namespace rm_modloader::profiler;
int main() {
    {
        // Ruby method -> native method -> Ruby method, including native frame
        // push/pop timing and a partial first/last frame.
        std::vector<Event> e = {{0,1,1,1000,Call}, {10,1,2,1000,CCall},
            {15,1,3,912,Call}, {20,1,3,912,Return}, {30,1,2,1000,CReturn},
            {35,1,0,1000,Frame}, {40,1,1,1000,Return}, {45,1,0,1000,Frame}};
        auto s = summarize(e,4,0,50);
        assert(s.methods[1].self == 20 && s.methods[1].total == 40);
        assert(s.methods[2].self == 15 && s.methods[2].total == 20);
        assert(s.methods[3].self == 5 && s.unattributed == 10);
        assert(s.unmatched_returns == 0 && s.frames.size() == 3);
        assert(s.frames[0].partial && !s.frames[1].partial && s.frames[2].partial);
    }
    {
        // Suspended Fiber does not accumulate another Fiber's active time.
        std::vector<Event> e = {{0,1,1,1000,Call}, {10,2,2,2000,Call},
            {30,1,1,1000,Return}, {40,2,2,2000,Return}};
        auto s = summarize(e,3,0,40);
        assert(s.methods[1].total == 10 && s.methods[2].total == 20);
        assert(s.unattributed == 10 && s.context_changes == 3);
    }
    {
        // Recursive totals must not double-count the same interval.
        std::vector<Event> e = {{0,1,1,1000,Call}, {10,1,1,956,Call},
            {20,1,1,956,Return}, {30,1,1,1000,Return}};
        auto s = summarize(e,2,0,30);
        assert(s.methods[1].calls == 2 && s.methods[1].completed == 2);
        assert(s.methods[1].self == 30 && s.methods[1].total == 30);
    }
    {
        // Native exception skips C_RETURN; the parent's Ruby RETURN recovers.
        std::vector<Event> e = {{0,1,1,1000,Call}, {10,1,2,1000,CCall},
            {15,1,0,956,Raise}, {20,1,1,1000,Return}};
        auto s = summarize(e,3,0,25);
        assert(s.methods[2].unwound == 1 && s.methods[1].completed == 1);
        assert(s.raises == 1 && s.unattributed == 5);
    }
    {
        // Start/end mid-call; unknown returns cannot corrupt another frame.
        std::vector<Event> e = {{2,1,1,1000,Return}, {5,1,2,1000,Call},
            {8,1,1,956,Return}};
        auto s = summarize(e,3,0,20);
        assert(s.unmatched_returns == 2 && s.methods[2].open_at_stop == 1);
        assert(s.methods[2].self == 15 && s.unattributed == 5);
    }
    {
        // Captured RGSS behavior: non-local return from a block emits C_RETURN
        // at the native frame, then RETURN at its Ruby parent. Do not leave the
        // iterator active and charge the parent's remaining work to it.
        for (uint32_t native_return_frame : {956u, 1000u}) {
            std::vector<Event> e = {{0,1,1,1000,Call}, {10,1,2,1000,CCall},
                {15,1,3,868,Call}, {20,1,3,868,Return},
                {30,1,2,native_return_frame,CReturn}, {40,1,1,1000,Return}};
            auto s = summarize(e,4,0,40);
            assert(s.unmatched_returns == 0 && s.methods[2].unwound == 0);
            assert(s.methods[2].completed == 1 && s.methods[2].open_at_stop == 0);
            assert(s.methods[2].self == 15 && s.methods[2].total == 20);
            assert(s.methods[1].self == 20);
        }
    }
    {
        // Recursive native method: match the nearest activation, preserve the
        // suspended Fiber and reject a Ruby RETURN with a native frame address.
        std::vector<Event> e = {{0,1,1,1000,CCall}, {10,1,1,956,CCall},
            {12,2,2,2000,Call}, {15,2,2,2000,Return},
            {20,1,1,912,CReturn}, {25,1,1,956,Return}, {30,1,1,1000,CReturn}};
        auto s = summarize(e,3,0,30);
        assert(s.unmatched_returns == 1 && s.methods[1].completed == 2);
        assert(s.methods[1].unwound == 0 && s.methods[1].open_at_stop == 0);
        assert(s.methods[1].self == 22 && s.methods[1].total == 22);
    }
    std::cout << "Native profiler replay tests passed\n";
}
