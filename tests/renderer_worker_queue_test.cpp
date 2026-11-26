#include "../src/ModLoader/Hooks/Renderer/SnapshotExecution.hpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

// The renderer exception itself needs no allocation. Fail exactly the subsequent
// diagnostic string copy on the worker, leaving owner setup/cleanup untouched.
static std::atomic<bool> fail_next_allocation{false};
static std::atomic<int> render_failure{0};
void* operator new(size_t bytes) {
    if (fail_next_allocation.exchange(false)) throw std::bad_alloc();
    if (void* memory = std::malloc(bytes ? bytes : 1)) return memory;
    throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, size_t) noexcept { std::free(memory); }

struct RenderError : std::exception {
    const char* what() const noexcept override {
        return "A deliberately long render failure diagnostic that exceeds small string storage, "
               "so copying it exercises the allocation failure in the worker exception handler.";
    }
};
namespace rm_modloader::renderer {
// Replace only the RGSS compositor/Surface destructor in this standalone test;
// the actual SnapshotExecution render callback and WorkerQueue are exercised.
void render_walk(Sprite*, Surface* destination, DWORD*, int*, RECT*) {
    assert(snapshot_drawing());
    destination->left_offset = 123;
    switch (render_failure.load()) {
    case 1: throw RenderError();
    case 2: fail_next_allocation = true; throw RenderError();
    case 3: throw 7;
    }
}
void SurfaceDeleter::operator()(Surface* surface) const { delete surface; }
}

using namespace rm_modloader;
using namespace rm_modloader::renderer;
static BITMAPINFO bitmap_info{};
static void test_callback(WorkerJob& work) noexcept {
    render_worker_job(work);
    assert(!snapshot_drawing());
    assert(work.target->left_offset == 7 && work.target->top_offset == 8);
    assert(work.target->rect.left == 10 && work.target->rect.bottom == 13);
}
static std::unique_ptr<WorkerJob> prepare(std::unique_ptr<WorkerJob> work = {}) {
    if (!work) work = std::make_unique<WorkerJob>();
    clear_worker_error(*work);
    work->done = false;
    work->completed = 0;
    work->repeats = 1;
    work->width = work->height = 1;
    work->pitch = 4;
    work->background = std::make_unique<unsigned char[]>(4);
    std::memset(work->background.get(), 19, 4);
    work->target = std::shared_ptr<Surface>(new Surface{}, [](Surface* surface) {
        delete[] surface->image.bits;
        delete surface;
    });
    work->target->image.bits = new unsigned char[4];
    work->target_pixels = work->target->image.bits;
    work->target->info.bitmap = &bitmap_info;
    work->target->left_offset = 7;
    work->target->top_offset = 8;
    work->target->rect = {10, 11, 12, 13};
    work->tree = std::make_unique<Snapshot>();
    auto node = std::make_unique<Node>();
    node->data = std::make_unique<unsigned char[]>(sizeof(Sprite));
    work->tree->nodes.push_back(std::move(node));
    return work;
}
static void await_completed(WorkerJob& work) {
    const auto deadline = GetTickCount64() + 5000;
    while (!work.done.load(std::memory_order_acquire) && GetTickCount64() < deadline) Sleep(1);
    assert(work.done.load(std::memory_order_acquire));
    assert(work.thread_id != GetCurrentThreadId());
}
int main() {
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biWidth = bitmap_info.bmiHeader.biHeight = 1;
    RenderWorkerQueue queue(&test_callback);
    for (int failure : {1, 2, 3}) {
        render_failure = failure;
        auto work = prepare();
        auto* observed = work.get();
        queue.enqueue(std::move(work));
        await_completed(*observed);
        queue.wait(*observed);
        assert(!job_error(*observed).empty() && observed->completed == 0);
        if (failure == 1) assert(job_error(*observed) == RenderError{}.what());
        if (failure == 2) {
            assert(observed->fallback_error != nullptr);
            assert(job_error(*observed) == "Worker render failed; diagnostic allocation failed");
            assert(!fail_next_allocation.load());
        }
        if (failure == 3) assert(job_error(*observed) == "Unknown worker exception");
        const auto worker_thread = observed->thread_id;
        queue.pop(true);

        // Recover on the same persistent thread using the same recycled Job.
        auto recycled = queue.take_recycled(true);
        assert(recycled.get() == observed);
        render_failure = 0;
        auto next = prepare(std::move(recycled));
        observed = next.get();
        queue.enqueue(std::move(next));
        await_completed(*observed);
        queue.wait(*observed);
        assert(job_error(*observed).empty() && observed->fallback_error == nullptr);
        assert(observed->thread_id == worker_thread);
        assert(observed->completed == 1 && observed->target_pixels[0] == 19);
        queue.pop(false);
    }
    assert(queue.pending() == 0);
    // Full Screen jobs clear their own destination; they must not dereference
    // an absent background. Partial/manual jobs above still restore it.
    auto screen = prepare();
    screen->initialize_background = false;
    screen->background.reset();
    screen->target_pixels[0] = 41;
    auto* observed = screen.get();
    queue.enqueue(std::move(screen));
    await_completed(*observed);
    queue.wait(*observed);
    assert(job_error(*observed).empty() && observed->completed == 1);
    assert(observed->target_pixels[0] == 41);
    queue.pop(false);
    std::puts("Renderer worker failure/recovery PASS");
}
