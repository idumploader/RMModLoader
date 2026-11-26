#pragma once
#include "SnapshotCapture.hpp"
#include "WorkerQueue.hpp"
#include <chrono>
#include <string_view>

namespace rm_modloader::renderer {
// Native execution boundary: captured data only, no Ruby values or live cache.
using Clock = std::chrono::steady_clock;
void render_tree(Sprite* root,Surface* destination,Snapshot* tree=nullptr);
bool snapshot_drawing();
bool drawing_viewport_scale(const Sprite*,int&,int&,Surface*&,const void*&);
    struct WorkerJob {
        Clock::time_point captured_at;
        SharedSurface expected;
        std::unique_ptr<Snapshot> tree;
        SharedSurface target;
        MemoryCharge background_memory;
        std::unique_ptr<unsigned char[]> background;
        size_t background_bytes=0;
        unsigned char* target_pixels = nullptr;
        int width = 0, height = 0, pitch = 0, repeats = 0;
        std::atomic<int> completed{0};
        std::atomic<bool> done{false};
        DWORD thread_id = 0;
        uint64_t frame_id = 0;
        bool restore_snapshot = false;
        bool initialize_background = true;
        double render_ms = 0;
        double tilemap_ms=0, viewport_source_ms=0, viewport_stretch_ms=0;
        std::string error;
        // Literal fallback survives allocation failure while reporting an error.
        const char* fallback_error = nullptr;
    };

std::string_view job_error(const WorkerJob& work) noexcept;
void clear_worker_error(WorkerJob& work) noexcept;
void render_worker_job(WorkerJob& work) noexcept;
void record_worker_tilemap(double) noexcept;
void record_worker_viewport_source(double) noexcept;
void record_worker_viewport_stretch(double) noexcept;
using RenderWorkerQueue = WorkerQueue<WorkerJob,2>;
}
