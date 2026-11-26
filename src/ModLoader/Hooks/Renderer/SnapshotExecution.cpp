#include "SnapshotExecution.hpp"
#include <cstring>
#include <stdexcept>

namespace rm_modloader::renderer {
namespace {
    // A worker must not suppress the owner's concurrent live compositor walk.
    thread_local bool drawing=false;
    thread_local Snapshot* drawing_snapshot=nullptr;
    thread_local WorkerJob* active_work=nullptr;
}
bool snapshot_drawing() { return drawing; }
void record_worker_tilemap(double ms) noexcept { if (active_work) active_work->tilemap_ms+=ms; }
void record_worker_viewport_source(double ms) noexcept { if (active_work) active_work->viewport_source_ms+=ms; }
void record_worker_viewport_stretch(double ms) noexcept { if (active_work) active_work->viewport_stretch_ms+=ms; }
    // Walk directly into an independently owned Bitmap; save/restore its mutable
    // clip/origin so later Bitmap operations do not inherit walker state.
    void render_tree(Sprite* root,Surface* destination,Snapshot* tree) {
        const auto* info = destination->info.bitmap;
        if (!info || info->bmiHeader.biBitCount != 32 || info->bmiHeader.biWidth <= 0 || info->bmiHeader.biHeight <= 0)
            throw std::runtime_error("Invalid destination bitmap");
        struct Restore {
            Surface* surface;
            int x, y;
            RECT clip;
            bool was_drawing;
            Snapshot* previous;
            ~Restore() {
                surface->left_offset = x; surface->top_offset = y; surface->rect = clip;
                drawing = was_drawing;
                drawing_snapshot=previous;
            }
        } restore{destination, destination->left_offset, destination->top_offset, destination->rect, drawing,drawing_snapshot};
        drawing = tree!=nullptr;
        drawing_snapshot=tree;
        destination->left_offset = destination->top_offset = 0;
        RECT clip{0, 0, info->bmiHeader.biWidth, info->bmiHeader.biHeight};
        destination->rect = clip;
        DWORD origin[2]{};
        int offset[2]{};
        render_walk(root,destination,origin,offset,&clip);
    }

bool drawing_viewport_scale(const Sprite* node,int& width,int& height,Surface*& target,const void*& attributes) {
    if (!drawing_snapshot) return false;
    const auto found=drawing_snapshot->viewport_scales.find(node);
    if (found==drawing_snapshot->viewport_scales.end()) return false;
    width=found->second.width; height=found->second.height; target=found->second.target.get();
    attributes=found->second.attributes.data();
    return true;
}
std::string_view job_error(const WorkerJob& work) noexcept {
    return work.fallback_error ? std::string_view(work.fallback_error) : std::string_view(work.error);
}
void clear_worker_error(WorkerJob& work) noexcept {
    work.error.clear();
    work.fallback_error = nullptr;
}
namespace {
    void record_worker_error(WorkerJob& work,const char* message) noexcept {
        try {
            work.error = message;
        } catch (...) {
            work.fallback_error = "Worker render failed; diagnostic allocation failed";
        }
    }
}
    void render_worker_job(WorkerJob& work) noexcept {
        struct WorkScope {
            WorkerJob* previous=active_work;
            WorkScope(WorkerJob& work) { active_work=&work; }
            ~WorkScope() { active_work=previous; }
        } scope(work);
        work.tilemap_ms=work.viewport_source_ms=work.viewport_stretch_ms=0;
        clear_worker_error(work);
        work.thread_id = GetCurrentThreadId();
        const auto start = Clock::now();
        try {
            for (int i = 0; i < work.repeats; ++i) {
                if (work.initialize_background)
                    for (int y = 0; y < work.height; ++y)
                        std::memcpy(work.target_pixels + ptrdiff_t(y) * work.pitch,
                            work.background.get() + size_t(y) * work.width * 4, size_t(work.width) * 4);
                render_tree(work.tree->nodes.front()->get(),work.target.get(),work.tree.get());
                work.completed.store(i + 1, std::memory_order_relaxed);
            }
        } catch (const std::exception& e) { record_worker_error(work,e.what()); }
        catch (...) { record_worker_error(work,"Unknown worker exception"); }
        work.render_ms=std::chrono::duration<double,std::milli>(Clock::now()-start).count();
    }

}
