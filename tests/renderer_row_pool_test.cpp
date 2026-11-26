#include "../src/ModLoader/Hooks/Renderer/RowPool.hpp"
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>

using rm_modloader::renderer::RowPool;
struct Work {
    int count;
    std::array<int,3> calls{};
    std::array<std::thread::id,3> threads{};
    std::atomic<int> entered{0};
    std::atomic<bool> timed_out{false};
};
static void concurrent(void* context,int band) noexcept {
    auto& work=*static_cast<Work*>(context);
    work.threads[band]=std::this_thread::get_id();
    ++work.calls[band];
    ++work.entered;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while (work.entered.load()!=work.count) {
        if (std::chrono::steady_clock::now()>deadline) {
            work.timed_out=true;
            break;
        }
        std::this_thread::yield();
    }
}
static void write_band(void* context,int band) noexcept {
    auto& work=*static_cast<Work*>(context);
    ++work.calls[band];
}
int main() {
    for (int count : {2,3}) {
        RowPool pool(count);
        Work work{count};
        pool.run(&concurrent,&work);
        assert(!work.timed_out && work.entered==count);
        assert(work.threads[0]==std::this_thread::get_id());
        for (int band=0;band<count;++band) {
            assert(work.calls[band]==1);
            for (int other=0;other<band;++other)
                assert(work.threads[band]!=work.threads[other]);
        }
        // Returning from every operation is a barrier: all bands are visible
        // before a subsequent compositor layer can be submitted.
        for (int layer=0;layer<500;++layer) {
            pool.run(&write_band,&work);
            for (int band=0;band<count;++band) assert(work.calls[band]==layer+2);
        }
    }
    std::puts("Raster row pool concurrency/barrier/shutdown PASS");
}
