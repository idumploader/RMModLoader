#pragma once
#include <Windows.h>
#include <process.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <stdexcept>
namespace rm_modloader::renderer {
// Owner thread exclusively manages slots/recycling. The callback only receives
// a captured Job; completion publication is the final worker access to that Job.
template<typename Job, size_t Capacity>
class WorkerQueue {
public:
    static constexpr size_t capacity = Capacity;
private:
        static_assert(Capacity>0);
        // Only the owner thread changes slots, head, count and serial.
        std::array<std::unique_ptr<Job>, capacity> slots;
        std::array<std::unique_ptr<Job>, capacity> recycled;
        size_t head = 0, count = 0;
        uint64_t serial = 0;
        std::mutex mutex;
        std::condition_variable wake;
        std::array<Job*, capacity> ready{};
        size_t ready_head = 0, ready_count = 0;
        bool stopping = false;
        HANDLE thread = nullptr;

        // Callback owns its exception boundary: it must report failures in Job
        // without allocating in its fallback and always return for publication.
        void (*render)(Job&) noexcept;
        static unsigned __stdcall entry(void* context) {
            auto& queue = *static_cast<WorkerQueue*>(context);
            for (;;) {
                Job* work;
                {
                    std::unique_lock lock(queue.mutex);
                    queue.wake.wait(lock, [&] { return queue.stopping || queue.ready_count != 0; });
                    if (queue.stopping) return 0;
                    work = queue.ready[queue.ready_head];
                    queue.ready_head = (queue.ready_head + 1) % capacity;
                    --queue.ready_count;
                }
                queue.render(*work);
                {
                    std::lock_guard lock(queue.mutex);
                    work->done.store(true, std::memory_order_release);
                }
                // No access to work after publishing completion: collect may free it.
                queue.wake.notify_all();
            }
        }
public:
        size_t pending() const { return count; }
        void clear_recycled() { for (auto& work : recycled) work.reset(); }
        explicit WorkerQueue(void (*render_job)(Job&) noexcept) : render(render_job) {
            thread = reinterpret_cast<HANDLE>(_beginthreadex(nullptr, 0, entry, this, 0, nullptr));
            if (!thread) throw std::runtime_error("Cannot start persistent render worker");
        }
        Job* front() { return count ? slots[head].get() : nullptr; }
        void wait(Job& work) {
            std::unique_lock lock(mutex);
            wake.wait(lock, [&] { return work.done.load(std::memory_order_acquire); });
        }
        void enqueue(std::unique_ptr<Job> work) {
            if (count == capacity) throw std::runtime_error("Render queue is full (two pending frames)");
            // Lock before moving ownership, so enqueue cannot lose a captured tree.
            std::lock_guard lock(mutex);
            work->frame_id = ++serial;
            auto* ptr = work.get();
            slots[(head + count) % capacity] = std::move(work);
            ++count;
            ready[(ready_head + ready_count) % capacity] = ptr;
            ++ready_count;
            wake.notify_all();
        }
        std::unique_ptr<Job> take_recycled(bool reuse) {
            if (reuse)
                for (auto& work : recycled)
                    if (work && work->target.use_count()==1) return std::move(work);
            return std::make_unique<Job>();
        }
        void pop(bool reuse) {
            auto work = std::move(slots[head]);
            head = (head + 1) % capacity;
            --count;
            work->tree.reset();
            if (reuse)
                for (auto& slot : recycled) if (!slot) { slot = std::move(work); break; }
        }
        void drain(bool reuse=false) { while (auto* work = front()) { wait(*work); pop(reuse); } }
        ~WorkerQueue() {
            drain();
            { std::lock_guard lock(mutex); stopping = true; }
            wake.notify_all();
            WaitForSingleObject(thread, INFINITE);
            CloseHandle(thread);
        }
    };
}
