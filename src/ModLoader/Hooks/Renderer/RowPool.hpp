#pragma once
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include <stdexcept>

namespace rm_modloader::renderer {
// A synchronous barrier between compositor operations preserves layer order.
// The coordinator paints band0; persistent helpers paint the remaining bands.
class RowPool {
    std::vector<std::thread> helpers_;
    std::mutex mutex_,dispatch_;
    std::condition_variable go_,done_;
    void (*function_)(void*,int) noexcept=nullptr;
    void* context_=nullptr;
    int next_=0,chunks_=0,remaining_=0;
    bool stop_=false;
    void loop() {
        for (;;) {
            int band;
            void (*function)(void*,int) noexcept;
            void* context;
            {
                std::unique_lock lock(mutex_);
                go_.wait(lock,[&]{return stop_ || next_<chunks_;});
                if (stop_) return;
                band=next_++; function=function_; context=context_;
            }
            function(context,band);
            {
                std::lock_guard lock(mutex_);
                if (!--remaining_) done_.notify_all();
            }
        }
    }
    void join() noexcept {
        { std::lock_guard lock(mutex_); stop_=true; }
        go_.notify_all();
        for (auto& thread:helpers_) if (thread.joinable()) thread.join();
    }
public:
    explicit RowPool(int count) {
        if (count<2 || count>3) throw std::runtime_error("Expected 2..3 raster threads");
        try { for (int i=1;i<count;++i) helpers_.emplace_back([this]{loop();}); }
        catch (...) { join(); throw; }
    }
    void run(void (*function)(void*,int) noexcept,void* context) {
        std::lock_guard dispatch(dispatch_);
        const int count=int(helpers_.size())+1;
        {
            std::lock_guard lock(mutex_);
            function_=function; context_=context;
            chunks_=count; next_=1; remaining_=count-1;
        }
        go_.notify_all();
        function(context,0);
        std::unique_lock lock(mutex_);
        done_.wait(lock,[&]{return remaining_==0;});
        function_=nullptr; context_=nullptr; chunks_=next_=0;
    }
    ~RowPool() { join(); }
};
}
