#include "../ParallelRenderer.hpp"
#include "RendererService.hpp"
#include "RubyBindings.hpp"
#include "MemoryBudget.hpp"
#include "SurfaceResources.hpp"
#include "SnapshotReplay.hpp"
#include "SnapshotCapture.hpp"
#include "SnapshotExecution.hpp"
#include "RasterWorkers.hpp"
#include "../MapFrameProbe.hpp"
#include "../RenderIntegration.hpp"
#include "../ViewportEffectsHooks.hpp"
#include "../HRFixHooks.hpp"
#include "../SteamOverlayHooks.hpp"
#include "../../ModLoader.hpp"
#include "../../RMGlobal.hpp"
#include "../../Hook.hpp"

#include <chrono>
#include <atomic>
#include <array>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cmath>
#include <limits>

namespace rm_modloader {
namespace {
    using Clock = std::chrono::steady_clock;
    using renderer::OwnedSurface;
    using renderer::SharedSurface;
    using renderer::make_surface;
    using renderer::pixels;
    using renderer::stride;
    using renderer::max_nodes;
    using renderer::Snapshot;
    using renderer::LiveViewportEffect;
    using renderer::default_pixel_limit_mib;
    using renderer::pixel_limit_mib;
    using renderer::max_pixel_bytes;
    using renderer::renderer_bytes;
    using renderer::renderer_peak_bytes;
    using renderer::SnapshotCapacity;
    using renderer::MemoryCharge;
    bool tilemap_hrfix = false;

    OwnedSurface rotation_scratch;
    DWORD owner_thread = 0;
    struct FrameState {
        int mode = 0;
        uint64_t submits=0, collects=0, checks=0;
        uint64_t repeats=0;
        SharedSurface presented;
        bool validation=false;
        double age_ms=0;
        Clock::time_point last_present{};
        uint64_t intervals=0, intervals_over25=0, intervals_over40=0, skipped=0;
        double interval_ms=0, interval_max_ms=0;
        double submit_ms=0, wait_ms=0, copy_ms=0, worker_ms=0;
        double prepare_ms=0, capture_tree_ms=0, enqueue_ms=0;
        double worker_tilemap_ms=0,worker_viewport_source_ms=0,worker_viewport_stretch_ms=0;
        std::string error;
        bool fallback=false;
        uint64_t fallbacks=0;
        bool capacity_fallback=false;
        Clock::time_point retry_at{};
        unsigned capacity_backoff_ms=100;
    } frames;
    SharedSurface strip_canvas;
    SharedSurface last_screen_frame, last_live_canvas;
    Surface* last_borrowed_surface=nullptr;
    bool last_frame_enabled=false, last_frame_valid=false;
    int last_frame_rows=0;
    uint64_t last_frame_copies=0, last_frame_hits=0;
    double last_frame_capture_ms=0, last_frame_read_ms=0;
    bool presentation_active=false, strip_checked=false, strip_ready=false;
    uint64_t strip_frames=0, strip_copies=0;
    uint64_t strip_checks=0;
    int optimization = 0; // 0: baseline, 1: source cache, 2: cache + target pool
    int render_workers=1;
    bool direct_output_enabled=false;
    bool parallel_stretch_enabled=false;
    bool direct_output_requested=false, direct_output_ready=false;
    uint64_t direct_presentations=0;
    unsigned direct_checks=0;
    renderer::SurfaceCache surface_cache;
    uint64_t target_reuses=0;
    void require_operation(bool allow_frame_mode=false) {
        if (frames.mode && !allow_frame_mode)
            throw std::runtime_error("Disable automatic frame mode before manual snapshot operations");
        if (GetCurrentThreadId()!=owner_thread)
            throw std::runtime_error("Parallel renderer must run on the game thread");
    }
    renderer::CaptureContext capture_context() {
        if (GetCurrentThreadId()!=owner_thread) throw std::runtime_error("Parallel renderer must run on the game thread");
        return {surface_cache,optimization!=0,rotation_scratch,tilemap_hrfix,
            owner_thread,rgss_module,*rgss_game ? (*rgss_game)->screen : nullptr};
    }
    void clear_surface_cache() { surface_cache.clear(); }
    void invalidate_surface(Surface* source) {
        if (GetCurrentThreadId()==owner_thread) surface_cache.invalidate(source);
    }
    void invalidate_last_borrow(Surface* source) {
        if (GetCurrentThreadId()==owner_thread && source && source==last_borrowed_surface) {
            last_borrowed_surface=nullptr; last_frame_valid=false;
        }
    }
    struct SurfaceTracking : Surface {
        static void (__thiscall Surface::* original_destroy)();
        static int (__thiscall Surface::* original_init)(int, int);
        static DWORD (__thiscall Surface::* original_release_dc)();
        DWORD __thiscall release_dc_hook() {
            // Native freeze/snap_to_bitmap write through an image DC, bypassing
            // Ruby Bitmap mutation hooks. Drop the cached version after GDI use.
            const auto result=(this->*original_release_dc)();
            if (!presentation_active) invalidate_last_borrow(this);
            invalidate_surface(this);
            return result;
        }
        void __thiscall destroy_hook() {
            invalidate_last_borrow(this);
            invalidate_surface(this);
            (this->*original_destroy)();
        }
        int __thiscall init_hook(int w, int h) {
            invalidate_last_borrow(this);
            invalidate_surface(this);
            return (this->*original_init)(w, h);
        }
    };
    void (__thiscall Surface::* SurfaceTracking::original_destroy)() = nullptr;
    int (__thiscall Surface::* SurfaceTracking::original_init)(int, int) = nullptr;
    DWORD (__thiscall Surface::* SurfaceTracking::original_release_dc)() = nullptr;

    std::unique_ptr<Snapshot> snapshot;
    std::string last_error;
    const char* api_error_fallback=nullptr;
    double capture_ms = 0, draw_ms = 0;

    double elapsed(Clock::time_point start) {
        return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
    }

    void draw(Sprite* root,Surface* destination,Snapshot* tree=nullptr) {
        invalidate_surface(destination);
        renderer::render_tree(root,destination,tree);
    }
    using renderer::WorkerJob;
    DWORD last_worker_thread = 0;
    double last_worker_ms = 0;
    int last_worker_repeats = 0;
    uint64_t last_frame_id = 0;
    double last_wait_ms = 0, last_collect_ms = 0, last_submit_ms = 0;
    double original_clear_ms = 0, original_draw_ms = 0, original_total_ms = 0;
    int original_frames = 0;

    using FrameQueue = renderer::RenderWorkerQueue;
    // Explicit lifecycle outside DllMain; never join under the DLL loader lock.
    FrameQueue* worker_queue = nullptr;
    FrameQueue& queue() {
        renderer::ensure_raster_workers();
        if (!worker_queue) worker_queue=new FrameQueue(&renderer::render_worker_job);
        return *worker_queue;
    }
    void discard_worker() { if (worker_queue) worker_queue->drain(optimization==2); }

    // Reject live-only viewport composition before allocating/copying full-screen
    // targets or drawing the bootstrap frame. Original-map-size scaling also uses
    // these effects and can remain active for the entire scene.
    void check_frame_effects(const Sprite* node, size_t& count, unsigned depth=0) {
        if (!node || depth>64 || ++count>max_nodes)
            throw std::runtime_error("Invalid, cyclic or oversized render tree");
        int width=0,height=0;
        if (viewport_has_custom_effect(node) && !viewport_snapshot_source_size(node,width,height))
            throw LiveViewportEffect();
        const uintptr_t begin=reinterpret_cast<uintptr_t>(node->child_begin);
        const uintptr_t end=reinterpret_cast<uintptr_t>(node->child_end);
        if (end<begin || (end-begin)%sizeof(Sprite*) ||
            (end-begin)/sizeof(Sprite*)>max_nodes || (!begin && end))
            throw std::runtime_error("Invalid child range");
        const size_t children=(end-begin)/sizeof(Sprite*);
        for (size_t i=0;i<children;++i) check_frame_effects(node->child_begin[i],count,depth+1);
    }

    std::unique_ptr<Snapshot> capture_tree(Sprite* root,bool detached) {
        auto next = std::make_unique<Snapshot>(true);
        next->copy_node(capture_context(),root, !detached ? nullptr : &next->parent);
        next->visited.clear();
        return next;
    }

    std::unique_ptr<WorkerJob> prepare_surface_job(Surface* source,int repeats,bool preserve_background=true) {
        if (repeats < 1 || repeats > 10000)
            throw std::runtime_error("Worker repeats must be between 1 and 10000");
        auto next = queue().take_recycled(optimization==2);
        Snapshot staging;
        const auto* info = source->info.bitmap;
        if (!info || info->bmiHeader.biBitCount != 32 || info->bmiHeader.biCompression != BI_RGB)
            throw std::runtime_error("Only 32-bit BI_RGB templates are supported");
        if (!next->target || next->width != info->bmiHeader.biWidth || next->height != info->bmiHeader.biHeight) {
            if (preserve_background) {
                staging.copy_surface(capture_context(),source);
                next->target=std::move(staging.surfaces.at(source));
            } else {
                next->target=SharedSurface(make_surface(info->bmiHeader.biWidth,info->bmiHeader.biHeight));
            }
        } else {
            ++target_reuses;
        }
        next->width = next->target->info.bitmap->bmiHeader.biWidth;
        next->height = next->target->info.bitmap->bmiHeader.biHeight;
        next->pitch = stride(next->target.get());
        next->target_pixels = pixels(next->target.get());
        const size_t background_bytes=preserve_background ? size_t(next->width)*next->height*4 : 0;
        if (next->background_bytes!=background_bytes) {
            next->background.reset(); next->background_memory.clear(); next->background_bytes=0;
            if (background_bytes) {
                next->background_memory.add(background_bytes);
                next->background=std::make_unique<unsigned char[]>(background_bytes);
            }
            next->background_bytes=background_bytes;
        }
        if (preserve_background) {
            const auto* src=pixels(source);
            const int src_pitch=stride(source);
            if (!src || (src_pitch>-next->width*4 && src_pitch<next->width*4))
                throw std::runtime_error("Invalid template pixel layout");
            for (int y=0;y<next->height;++y)
                std::memcpy(next->background.get()+size_t(y)*next->width*4,
                            src+ptrdiff_t(y)*src_pitch,size_t(next->width)*4);
        }
        next->initialize_background=preserve_background;
        next->repeats = repeats;
        next->completed.store(0);
        next->done.store(false);
        next->thread_id = 0;
        next->render_ms = 0;
        renderer::clear_worker_error(*next);
        next->restore_snapshot = false;
        next->expected.reset();
        return next;
    }

    void submit_screen_job(FrameQueue& worker,Screen* screen,Surface* dest,
        Clock::time_point submit_start,bool timestamp_capture) {
        const auto prepare_start=Clock::now();
        // A full Screen begins with Screen::render_clearbg (slot9), which
        // replaces every pixel. Only manual/partial APIs need the old Bitmap.
        auto job=prepare_surface_job(dest,1,false);
        frames.prepare_ms+=elapsed(prepare_start);
        if (timestamp_capture) job->captured_at=Clock::now();
        const auto capture_start=Clock::now();
        job->tree=capture_tree((*rgss_game)->screen,false);
        frames.capture_tree_ms+=elapsed(capture_start);
        if (frames.validation && frames.submits<6) {
            Snapshot validation;
            validation.copy_surface(capture_context(),dest);
            job->expected=std::move(validation.surfaces.at(dest));
            draw(screen,job->expected.get());
        }
        const auto enqueue_start=Clock::now();
        worker.enqueue(std::move(job));
        frames.enqueue_ms+=elapsed(enqueue_start);
        ++frames.submits;
        frames.submit_ms+=elapsed(submit_start);
    }

}

namespace renderer::service {
void set_mode(int value) {
    require_operation(true);
    if (value<0 || value>3) throw std::runtime_error("Expected frame mode 0..3");
    last_borrowed_surface=nullptr;
    last_screen_frame.reset(); last_live_canvas.reset(); last_frame_valid=false;
    frames.mode=0;
    discard_worker(); snapshot.reset();
    frames.presented.reset(); frames.repeats=0; frames.age_ms=0;
    strip_canvas.reset(); strip_checked=strip_ready=false;
    strip_frames=strip_copies=0;
    strip_checks=0;
    if (!value) {
        delete worker_queue; worker_queue=nullptr;
        renderer::reset_raster_workers();
        rotation_scratch.reset(); clear_surface_cache();
    }
    frames.last_present={}; frames.intervals=frames.intervals_over25=frames.intervals_over40=frames.skipped=0;
    frames.interval_ms=frames.interval_max_ms=0;
    frames.submits=frames.collects=frames.checks=0;
    direct_checks=0;
    frames.submit_ms=frames.wait_ms=frames.copy_ms=frames.worker_ms=0;
    frames.prepare_ms=frames.capture_tree_ms=frames.enqueue_ms=0;
    frames.worker_tilemap_ms=frames.worker_viewport_source_ms=frames.worker_viewport_stretch_ms=0;
    frames.error.clear();
    frames.fallback=false; frames.fallbacks=0;
    frames.capacity_fallback=false; frames.retry_at={}; frames.capacity_backoff_ms=100;
    frames.mode=value;

}
void set_memory_limit(int mib) {
    require_operation(true);
    if (mib<32 || mib>512)
        throw std::runtime_error("Expected renderer memory limit 32..512 MiB");
    if (GetCurrentThreadId()!=owner_thread)
        throw std::runtime_error("Renderer memory limit must be changed on the game thread");
    pixel_limit_mib=static_cast<unsigned>(mib);
    max_pixel_bytes=size_t(pixel_limit_mib)*1024*1024;
    if (renderer_bytes.load()>max_pixel_bytes) {
        last_borrowed_surface=nullptr;
        last_screen_frame.reset(); last_live_canvas.reset(); last_frame_valid=false;
        discard_worker();
        frames.presented.reset(); strip_canvas.reset(); snapshot.reset();
        delete worker_queue; worker_queue=nullptr;
        renderer::reset_raster_workers();
        clear_surface_cache(); rotation_scratch.reset();
        strip_checked=strip_ready=false;
    }
    frames.retry_at={}; // a raised limit may allow the next frame immediately
    frames.capacity_backoff_ms=100;

}
void set_workers(int value) {
    require_operation(true);
    if (value<1 || value>3) throw std::runtime_error("Expected 1..3 render workers");
    if (value==render_workers) return;
    const int mode=frames.mode;
    set_mode(0); // Join every old worker before changing independent frame ownership.
    render_workers=value;
    renderer::set_raster_worker_count(value);
    set_mode(mode);
}
int workers() { return render_workers; }
void set_direct_output(bool value) {
    require_operation(true);
    direct_output_enabled=value;
}
bool direct_output() { return direct_output_enabled; }
void set_parallel_stretch(bool value) {
    require_operation(true);
    if (parallel_stretch_enabled==value) return;
    const int mode=frames.mode;
    set_mode(0);
    parallel_stretch_enabled=value;
    renderer::set_parallel_stretch(value);
    set_mode(mode);
}
bool parallel_stretch() { return parallel_stretch_enabled; }
void start(Surface* source,int repeats) {
    require_operation(false);
    if (worker_queue && worker_queue->pending()) throw std::runtime_error("Worker result is pending; collect or clear it first");
    if (!snapshot) throw std::runtime_error("No captured snapshot");
    const auto start = Clock::now();
    auto next = prepare_surface_job(source,repeats);
    auto& worker = queue(); // create thread before moving the synchronous snapshot
    next->restore_snapshot = true;
    next->tree = std::move(snapshot);
    worker.enqueue(std::move(next));
    last_submit_ms = elapsed(start);

}
void submit(Sprite* root,bool detached,Surface* source,int repeats) {
    require_operation(false);
    auto& worker = queue();
    if (worker.pending()==FrameQueue::capacity)
        throw std::runtime_error("Render queue is full (two pending frames)");
    const auto start = Clock::now();
    auto next = prepare_surface_job(source,repeats);
    next->tree = capture_tree(root,detached);
    worker.enqueue(std::move(next));
    last_submit_ms = elapsed(start);

}
void collect(Surface* destination) {
    require_operation(false);
    auto* job = worker_queue ? worker_queue->front() : nullptr;
    if (!job) throw std::runtime_error("No worker result");
    const auto* info = destination->info.bitmap;
    if (!info || info->bmiHeader.biBitCount != 32 ||
        info->bmiHeader.biWidth != job->width || info->bmiHeader.biHeight != job->height)
        throw std::runtime_error("Worker destination dimensions must match the template");
    const auto wait_start = Clock::now();
    worker_queue->wait(*job);
    last_wait_ms = elapsed(wait_start);
    if (!renderer::job_error(*job).empty()) throw std::runtime_error(std::string(renderer::job_error(*job)));
    const auto copy_start = Clock::now();
    invalidate_surface(destination);
    auto* dest_pixels = pixels(destination);
    const int dest_pitch = stride(destination);
    if (!dest_pixels || (dest_pitch > -job->width * 4 && dest_pitch < job->width * 4))
        throw std::runtime_error("Invalid worker destination pixel layout");
    for (int y = 0; y < job->height; ++y)
        std::memcpy(dest_pixels + ptrdiff_t(y) * dest_pitch,
            job->target_pixels + ptrdiff_t(y) * job->pitch, size_t(job->width) * 4);
    draw_ms = job->render_ms;
    last_worker_thread = job->thread_id;
    last_worker_ms = job->render_ms;
    last_worker_repeats = job->completed.load(std::memory_order_relaxed);
    last_frame_id = job->frame_id;
    if (job->restore_snapshot) snapshot = std::move(job->tree);
    worker_queue->pop(optimization==2);
    last_collect_ms = elapsed(copy_start);

}
void capture(Sprite* root,bool detached) {
    require_operation(false);
    // Failure invalidates the old snapshot; never replay a stale frame.
    discard_worker();
    snapshot.reset();
    capture_ms = draw_ms = 0;
    const auto start = Clock::now();
    auto next = capture_tree(root,detached);
    capture_ms = elapsed(start);
    snapshot = std::move(next);

}
void draw_snapshot(Surface* destination) {
    require_operation(false);
    if (!snapshot) throw std::runtime_error("No captured snapshot");
    const auto start = Clock::now();
    draw(snapshot->nodes.front()->get(), destination,snapshot.get());
    draw_ms = elapsed(start);

}
void reference(Sprite* root,bool detached,Surface* destination) {
    require_operation(false);
    // Validate the same supported subset before calling any virtual render
    // function on the live tree. Reference rendering must not admit the
    // Rotation-cache writes intentionally excluded from Bitmap version tracking.
    Snapshot validation;
    validation.copy_node(capture_context(),root, !detached ? nullptr : &validation.parent);
    if (validation.surfaces.find(destination) != validation.surfaces.end())
        throw std::runtime_error("Destination cannot also be a source bitmap");
    draw(root, destination);

}
void clear() {
    require_operation(false);
    discard_worker(); snapshot.reset(); capture_ms=draw_ms=0;
}
void benchmark(Sprite* original_root,bool detached,Surface* destination,int count,bool use_snapshot) {
    require_operation(false);
    if (worker_queue && worker_queue->pending()) throw std::runtime_error("Clear pending frames before benchmarking live rendering");
    const int frames=count;
    if (frames < 1 || frames > 10000) throw std::runtime_error("Expected 1..10000 benchmark frames");
    if (use_snapshot && !snapshot) throw std::runtime_error("Capture before benchmarking snapshot rendering");
    Sprite* root = use_snapshot ? snapshot->nodes.front()->get() : original_root;
    Snapshot validation;
    validation.copy_node(capture_context(),original_root, !detached ? nullptr : &validation.parent);
    if (validation.surfaces.find(destination) != validation.surfaces.end())
        throw std::runtime_error("Destination cannot also be a source bitmap");
    using Fill = int (__thiscall*)(Surface*, RECT*, DWORD);
    auto fill = at_offset<Fill>(rgss_module, 0x10c450);
    invalidate_surface(destination);
    // Warm up the live paths and destination before starting the timer.
    fill(destination, nullptr, 0);
    draw(root, destination,use_snapshot ? snapshot.get() : nullptr);
    original_clear_ms = original_draw_ms = 0;
    original_frames = frames;
    const auto begin = Clock::now();
    for (int i = 0; i < frames; ++i) {
        const auto clear_begin = Clock::now();
        fill(destination, nullptr, 0);
        const auto draw_begin = Clock::now();
        original_clear_ms += std::chrono::duration<double, std::milli>(draw_begin - clear_begin).count();
        draw(root, destination,use_snapshot ? snapshot.get() : nullptr);
        original_draw_ms += elapsed(draw_begin);
    }
    original_total_ms = elapsed(begin);

}
void set_optimization(int mode) {
    require_operation(false);
    if (mode < 0 || mode > 2) throw std::runtime_error("Expected optimization mode 0..2");
    if (worker_queue && worker_queue->pending()) throw std::runtime_error("Collect or clear pending frames before switching optimization");
    snapshot.reset();
    clear_surface_cache();
    if (worker_queue) worker_queue->clear_recycled();
    optimization = mode;
    surface_cache.reset_counters(); target_reuses=0;

}
bool pixels_equal(Surface* left,Surface* right) {
    require_operation(true);

    const auto* li = left->info.bitmap;
    const auto* ri = right->info.bitmap;
    if (!li || !ri || li->bmiHeader.biBitCount != 32 || ri->bmiHeader.biBitCount != 32)
        throw std::runtime_error("Expected 32-bit comparison surfaces");
    const int w = li->bmiHeader.biWidth, h = li->bmiHeader.biHeight;
    if (w != ri->bmiHeader.biWidth || h != ri->bmiHeader.biHeight) { return false; }
    const auto* lp = pixels(left);
    const auto* rp = pixels(right);
    const int ls = stride(left), rs = stride(right);
    if (!lp || !rp || w <= 0 || h <= 0 ||
        (ls > -w * 4 && ls < w * 4) || (rs > -w * 4 && rs < w * 4))
        throw std::runtime_error("Invalid comparison pixel layout");
    for (int y = 0; y < h; ++y)
        if (std::memcmp(lp + ptrdiff_t(y) * ls, rp + ptrdiff_t(y) * rs, size_t(w) * 4)) { return false; }
    return true;
}
std::string frame_status() {

        const auto report=nlohmann::json{{"mode",frames.mode},{"submits",frames.submits},
    {"collects",frames.collects},{"checks",frames.checks},{"submit_ms",frames.submit_ms},
    {"wait_ms",frames.wait_ms},{"copy_ms",frames.copy_ms},{"worker_ms",frames.worker_ms},
    {"workers",render_workers},{"queue_limit",FrameQueue::capacity},
    {"direct_output",direct_output_enabled},{"direct_presentations",direct_presentations},
    {"direct_checks",direct_checks},
    {"parallel_stretch",parallel_stretch_enabled},
    {"prepare_ms",frames.prepare_ms},{"capture_tree_ms",frames.capture_tree_ms},{"enqueue_ms",frames.enqueue_ms},
    {"worker_tilemap_ms",frames.worker_tilemap_ms},{"worker_viewport_source_ms",frames.worker_viewport_source_ms},
    {"worker_viewport_stretch_ms",frames.worker_viewport_stretch_ms},
    {"repeated_frames",frames.repeats},{"age_ms",frames.age_ms},
    {"present_intervals",frames.intervals},{"present_interval_ms",frames.interval_ms},
    {"present_interval_max_ms",frames.interval_max_ms},{"present_over25",frames.intervals_over25},
    {"present_over40",frames.intervals_over40},{"skipped_results",frames.skipped},
    {"fallback",frames.fallback},{"fallback_frames",frames.fallbacks},
    {"capacity_fallback",frames.capacity_fallback},{"capacity_backoff_ms",frames.capacity_backoff_ms},
    {"pixel_limit_mib",pixel_limit_mib},
    {"memory_limit_mib",pixel_limit_mib},{"memory_bytes",renderer_bytes.load()},
    {"memory_peak_bytes",renderer_peak_bytes.load()},{"worker_running",worker_queue!=nullptr},
    {"validation",frames.validation},{"strip_frames",strip_frames},{"strip_copies",strip_copies},
    {"strip_checks",strip_checks},
    {"source_copied_bytes",surface_cache.statistics().copied_bytes},{"cache_hits",surface_cache.statistics().hits},{"cache_misses",surface_cache.statistics().misses},
    {"overlay_ready",steam_overlay_ready()},{"overlay_frames",steam_overlay_frame_count()},
    {"overlay_ms",steam_overlay_render_ms()},
    {"overlay_capture_ms",steam_overlay_capture_ms()},
    {"overlay_copied_bytes",steam_overlay_capture_bytes()},
    {"overlay_missing_frames",steam_overlay_missing_frames()},
    {"overlay_optimizations",steam_overlay_optimizations()},
    {"overlay_borrowed_frames",steam_overlay_borrowed_frames()},
    {"overlay_materialized_frames",steam_overlay_materialized_frames()},
    {"overlay_parallel_operations",steam_overlay_parallel_operations()},
    {"overlay_capture_pitch",steam_overlay_capture_pitch()},
    {"error",frames.error}}.dump();
        return report;

}
std::string status() {

        auto* job = worker_queue ? worker_queue->front() : nullptr;
        const bool done = job && job->done.load(std::memory_order_acquire);
        const std::string text = nlohmann::json{
    {"original_frames", original_frames}, {"original_clear_ms", original_clear_ms},
    {"original_draw_ms", original_draw_ms}, {"original_total_ms", original_total_ms},
    {"optimization", optimization}, {"source_copied_bytes", surface_cache.statistics().copied_bytes},
    {"cache_hits", surface_cache.statistics().hits}, {"cache_misses", surface_cache.statistics().misses}, {"cache_bytes", surface_cache.statistics().bytes},
    {"target_reuses", target_reuses},
    {"mode", job ? "worker" : "synchronous"}, {"captured", bool(snapshot)},
    {"worker_pending", job != nullptr}, {"worker_done", done},
    {"worker_completed", job ? job->completed.load(std::memory_order_relaxed) : 0},
    {"worker_repeats", job ? job->repeats : 0},
    {"worker_thread", done ? job->thread_id : 0}, {"owner_thread", owner_thread},
    {"worker_ms", done ? job->render_ms : 0}, {"worker_error", done ? std::string(renderer::job_error(*job)) : ""},
    {"last_worker_thread", last_worker_thread}, {"last_worker_ms", last_worker_ms},
    {"last_worker_repeats", last_worker_repeats},
    {"queue_depth",worker_queue ? worker_queue->pending() : 0},
    {"queue_capacity",FrameQueue::capacity},
    {"next_frame", job ? job->frame_id : 0}, {"last_frame", last_frame_id},
    {"last_submit_ms", last_submit_ms}, {"last_wait_ms", last_wait_ms}, {"last_collect_ms", last_collect_ms},
    {"nodes", snapshot ? snapshot->nodes.size() : 0},
    {"surfaces", snapshot ? snapshot->surfaces.size() : 0},
    {"node_bytes", snapshot ? snapshot->node_bytes : 0},
    {"tilemaps", snapshot ? snapshot->tilemaps.size() : 0},
    {"table_bytes", snapshot ? snapshot->table_bytes : 0},
    {"pixel_bytes", snapshot ? snapshot->pixel_bytes : 0},
    {"pixel_limit_mib",pixel_limit_mib},
    {"memory_limit_mib",pixel_limit_mib},{"memory_bytes",renderer_bytes.load()},
    {"memory_peak_bytes",renderer_peak_bytes.load()},{"worker_running",worker_queue!=nullptr},
    {"capture_ms", capture_ms}, {"draw_ms", draw_ms}, {"error", api_error_fallback ? api_error_fallback : last_error.c_str()}
        }.dump();
        return text;

}
void enable_last_frame(bool enabled) {
    require_operation(true);
        last_frame_enabled=enabled;
        if (!last_frame_enabled) {
            last_borrowed_surface=nullptr;
            last_screen_frame.reset(); last_live_canvas.reset(); last_frame_valid=false;
            if (frames.mode==2) frames.presented.reset();
        }

}
void copy_last_frame(Surface* dest) {
    require_operation(true);
        auto* source=last_borrowed_surface ? last_borrowed_surface : last_screen_frame.get();
        if (!source) throw std::runtime_error("No completed screen frame");
        const auto& info=dest->info.bitmap->bmiHeader;
        const auto& full=(*rgss_game)->screen->rect;
        const int w=full.right-full.left, h=full.bottom-full.top;
        if (info.biWidth!=w || info.biHeight!=h ||
            source->info.bitmap->bmiHeader.biWidth!=w ||
            source->info.bitmap->bmiHeader.biHeight!=h)
            throw std::runtime_error("Last frame dimensions changed");
        const auto start=Clock::now();
        invalidate_surface(dest);
        auto* out=pixels(dest); const auto* in=pixels(source);
        const int op=stride(dest), ip=stride(source);
        for (int row=0;row<h;++row)
            std::memcpy(out+ptrdiff_t(row)*op,in+ptrdiff_t(row)*ip,size_t(w)*4);
        ++last_frame_hits; last_frame_read_ms+=elapsed(start);

}
std::string last_frame_status() {
    const auto report=nlohmann::json{{"enabled",last_frame_enabled},{"valid",last_frame_valid},
        {"borrowed",last_borrowed_surface!=nullptr},
        {"hits",last_frame_hits},{"capture_copies",last_frame_copies},
        {"capture_ms",last_frame_capture_ms},{"read_ms",last_frame_read_ms}}.dump();
    return report;

}
void begin_api_operation(bool allow_frame_mode) {
    require_operation(allow_frame_mode);
    last_error.clear();
    api_error_fallback=nullptr;
}
void set_api_error(const char* error) noexcept {
    try {
        last_error=error;
        api_error_fallback=nullptr;
    } catch (...) {
        last_error.clear();
        api_error_fallback="Renderer API failed; diagnostic allocation failed";
    }
}
int current_mode() { return frames.mode; }
unsigned memory_limit() { return pixel_limit_mib; }
const std::string& frame_error() { return frames.error; }
int health() { return frames.error.empty() ? 0 : frames.mode==0 ? 2 : frames.capacity_fallback ? 3 : 1; }
void set_validation(bool enabled) {
    require_operation(true); frames.validation=enabled; }
void invalidate(Surface* source) {
    require_operation(false); invalidate_surface(source); }
void barrier() { if (frames.mode) {
    require_operation(true); discard_worker(); frames.presented.reset(); frames.last_present={}; } }
bool last_frame_ready() { return GetCurrentThreadId()==owner_thread && last_frame_valid; }
Sprite* screen_root() {
    if (!*rgss_game || !(*rgss_game)->screen) throw std::runtime_error("No live Screen");
    return (*rgss_game)->screen;
}
void notify_bitmap_changed(Surface* source) { invalidate_last_borrow(source); invalidate_surface(source); }
}

bool parallel_renderer_drawing() { return renderer::snapshot_drawing(); }

bool render_snapshot_viewport_scale(const Sprite* node,int& width,int& height,Surface*& target,const void*& attributes) {
    return renderer::drawing_viewport_scale(node,width,height,target,attributes);
}

static bool render_snapshot_full_frame(Screen* screen,Surface* dest,int x,int y,RECT* rect) {
    if (!frames.mode || GetCurrentThreadId()!=owner_thread) return false;
    // A transition can briefly keep the map and battle render trees alive.
    // Retry an oversized snapshot after a short pause, without recopying up to
    // 128 MiB on every frame while both trees coexist.
    if (frames.capacity_fallback && Clock::now()<frames.retry_at) {
        ++frames.fallbacks;
        return false;
    }
    try {
        const auto& size=dest->info.bitmap->bmiHeader;
        const auto* previous=worker_queue ? worker_queue->front() : nullptr;
        if ((frames.presented && (frames.presented->info.bitmap->bmiHeader.biWidth!=size.biWidth ||
             frames.presented->info.bitmap->bmiHeader.biHeight!=size.biHeight)) ||
            (previous && (previous->width!=size.biWidth || previous->height!=size.biHeight))) {
            discard_worker(); frames.presented.reset();
            delete worker_queue; worker_queue=nullptr;
            renderer::reset_raster_workers();
        }
        if (screen!=(*rgss_game)->screen || x || y ||
            (rect && std::memcmp(rect,&screen->rect,sizeof(RECT))))
            throw std::runtime_error("Parallel rendering requires a full Screen draw");
        const auto start=Clock::now();
        size_t effect_nodes=0;
        check_frame_effects(screen,effect_nodes);
        if (frames.mode==1) {
            auto tree=capture_tree((*rgss_game)->screen,false);
            frames.submit_ms+=elapsed(start);
            const auto render_start=Clock::now();
            draw(tree->nodes.front()->get(),dest,tree.get());
            frames.worker_ms+=elapsed(render_start);
            ++frames.submits; ++frames.collects;
            return true;
        }
        auto& worker=queue();
        if (frames.mode==3) {
            // One rendering job plus at most one queued snapshot keeps the worker
            // busy between Graphics.update calls without an unbounded backlog.
            // Present only the newest completed result and never wait here.
            bool received=false;
            auto* ready=worker.front();
            while (ready && ready->done.load(std::memory_order_acquire)) {
                if (!renderer::job_error(*ready).empty()) throw std::runtime_error(std::string(renderer::job_error(*ready)));
                if (ready->expected) {
                    auto* expected=pixels(ready->expected.get());
                    const int expected_pitch=stride(ready->expected.get());
                    for (int row=0;row<ready->height;++row)
                        if (std::memcmp(expected+ptrdiff_t(row)*expected_pitch,
                            ready->target_pixels+ptrdiff_t(row)*ready->pitch,size_t(ready->width)*4))
                            throw std::runtime_error("Nonblocking Screen pixels differ from captured reference");
                    ++frames.checks;
                }
                frames.presented=ready->target;
                frames.worker_ms+=ready->render_ms;
                frames.worker_tilemap_ms+=ready->tilemap_ms;
                frames.worker_viewport_source_ms+=ready->viewport_source_ms;
                frames.worker_viewport_stretch_ms+=ready->viewport_stretch_ms;
                frames.age_ms+=elapsed(ready->captured_at);
                ++frames.collects;
                if (received) ++frames.skipped;
                received=true;
                worker.pop(optimization==2);
                ready=worker.front();
            }
            if (received) {
                const auto presented_at=Clock::now();
                if (frames.last_present!=Clock::time_point{}) {
                    const double interval=std::chrono::duration<double,std::milli>(presented_at-frames.last_present).count();
                    ++frames.intervals; frames.interval_ms+=interval;
                    frames.interval_max_ms=(std::max)(frames.interval_max_ms,interval);
                    if (interval>25) ++frames.intervals_over25;
                    if (interval>40) ++frames.intervals_over40;
                }
                frames.last_present=presented_at;
            } else if (worker.pending()) {
                ++frames.repeats;
            }
            if (!frames.presented) {
                // Bootstrap once with a current image, never an uninitialized buffer.
                Snapshot initial;
                initial.copy_surface(capture_context(),dest);
                frames.presented=std::move(initial.surfaces.at(dest));
                draw(screen,frames.presented.get());
            }
            if (worker.pending()<FrameQueue::capacity) {
                submit_screen_job(worker,screen,dest,Clock::now(),true);
            }
            if (frames.presented->info.bitmap->bmiHeader.biWidth!=dest->info.bitmap->bmiHeader.biWidth ||
                frames.presented->info.bitmap->bmiHeader.biHeight!=dest->info.bitmap->bmiHeader.biHeight)
                throw std::runtime_error("Screen resized with a pending frame");
            if (direct_output_requested) {
                direct_output_ready=true;
            } else {
                const auto copy_start=Clock::now();
                invalidate_surface(dest);
                auto* out=pixels(dest);
                const auto* source=pixels(frames.presented.get());
                const int pitch=stride(dest), source_pitch=stride(frames.presented.get());
                const int width=dest->info.bitmap->bmiHeader.biWidth, height=dest->info.bitmap->bmiHeader.biHeight;
                for (int row=0;row<height;++row)
                    std::memcpy(out+ptrdiff_t(row)*pitch,source+ptrdiff_t(row)*source_pitch,size_t(width)*4);
                frames.copy_ms+=elapsed(copy_start);
            }
            frames.fallback=false; frames.error.clear();
            frames.capacity_fallback=false; frames.capacity_backoff_ms=100;
            return true;
        }
        const bool priming=worker.pending()==0;
        submit_screen_job(worker,screen,dest,start,false);
        // Show the original first frame, then present the previous completed job.
        // One job remains outstanding so the next Ruby update overlaps rendering.
        if (priming) {
            frames.fallback=false; frames.error.clear();
            frames.capacity_fallback=false; frames.capacity_backoff_ms=100;
            return false;
        }
        auto* ready=worker.front();
        const auto wait_start=Clock::now();
        worker.wait(*ready);
        frames.wait_ms+=elapsed(wait_start);
        if (!renderer::job_error(*ready).empty()) throw std::runtime_error(std::string(renderer::job_error(*ready)));
        if (ready->width!=dest->info.bitmap->bmiHeader.biWidth || ready->height!=dest->info.bitmap->bmiHeader.biHeight)
            throw std::runtime_error("Screen resized with a pending frame");
        if (ready->expected) {
            auto* expected=pixels(ready->expected.get());
            const int expected_pitch=stride(ready->expected.get());
            for (int row=0;row<ready->height;++row)
                if (std::memcmp(expected+ptrdiff_t(row)*expected_pitch,ready->target_pixels+ptrdiff_t(row)*ready->pitch,size_t(ready->width)*4))
                    throw std::runtime_error("Pipelined Screen pixels differ from captured reference");
            ++frames.checks;
        }
        if (direct_output_requested) {
            frames.presented=ready->target;
            direct_output_ready=true;
        } else {
            const auto copy_start=Clock::now();
            invalidate_surface(dest);
            auto* out=pixels(dest);
            const int pitch=stride(dest);
            for (int row=0;row<ready->height;++row)
                std::memcpy(out+ptrdiff_t(row)*pitch,ready->target_pixels+ptrdiff_t(row)*ready->pitch,size_t(ready->width)*4);
            frames.copy_ms+=elapsed(copy_start);
        }
        frames.worker_ms+=ready->render_ms;
        frames.worker_tilemap_ms+=ready->tilemap_ms;
        frames.worker_viewport_source_ms+=ready->viewport_source_ms;
        frames.worker_viewport_stretch_ms+=ready->viewport_stretch_ms;
        ++frames.collects;
        if (last_frame_enabled) frames.presented=ready->target;
        worker.pop(optimization==2);
        frames.fallback=false; frames.error.clear();
        frames.capacity_fallback=false; frames.capacity_backoff_ms=100;
        return true;
    } catch (const std::exception& error) {
        frames.error=error.what();
        // Known live-only effects temporarily use the original renderer in either
        // parallel mode. Waiting for frames must not turn a transient effect into
        // a permanent shutdown of the renderer.
        // Retry on the next update; once the effect ends, asynchronous frames resume.
        const bool capacity=dynamic_cast<const SnapshotCapacity*>(&error)!=nullptr;
        frames.capacity_fallback=(frames.mode==2 || frames.mode==3) && capacity;
        frames.fallback=(frames.mode==2 || frames.mode==3) &&
            (capacity || dynamic_cast<const LiveViewportEffect*>(&error));
        if (frames.fallback) {
            ++frames.fallbacks;
            if (frames.capacity_fallback) {
                frames.retry_at=Clock::now()+std::chrono::milliseconds(frames.capacity_backoff_ms);
                frames.capacity_backoff_ms=(std::min)(frames.capacity_backoff_ms*2u,2000u);
            }
        }
        else {
            frames.mode=0;
            mod_loader->log_warning("Frame snapshot disabled: {}", frames.error);
        }
        discard_worker();
        frames.presented.reset(); frames.last_present={};
        if (capacity || frames.mode==0) {
            snapshot.reset(); strip_canvas.reset(); strip_ready=false;
            delete worker_queue; worker_queue=nullptr;
            renderer::reset_raster_workers();
            clear_surface_cache(); rotation_scratch.reset();
        }
        return false; // restore normal live rendering on failure
    }
}

void begin_snapshot_presentation() {
    presentation_active=true;
    strip_checked=strip_ready=false;
}
void begin_direct_frame_output() {
    direct_output_requested=direct_output_enabled;
    direct_output_ready=false;
}
Surface* direct_frame_output_surface() {
    return direct_output_ready ? frames.presented.get() : nullptr;
}
std::shared_ptr<Surface> retain_completed_frame_surface(Surface* source) {
    if (source==frames.presented.get()) return frames.presented;
    return {};
}
void end_direct_frame_output() {
    if (direct_output_ready) ++direct_presentations;
    direct_output_requested=direct_output_ready=false;
}
void validate_direct_frame_output(HDC target,int left,int top,int result) {
    if (!frames.validation || !direct_output_ready || !target || !result || direct_checks>=6) return;
    try {
        const auto expected=frames.presented;
        const int width=expected->info.bitmap->bmiHeader.biWidth;
        const int height=expected->info.bitmap->bmiHeader.biHeight;
        auto actual=make_surface(width,height);
        using GetDC=HDC (__thiscall*)(Surface*);
        using Release=DWORD (__thiscall*)(Surface*);
        auto acquire=at_offset<GetDC>(rgss_module,0x10b6a0);
        auto release=at_offset<Release>(rgss_module,0x10b720);
        HDC dc=acquire(actual.get());
        // A window DC may expose only the visible/clipped client area (a 2560
        // window is narrower than the monitor after its borders are applied).
        // Validate the complete selected source bitmap through the same native
        // GDI blit into an independent offscreen target, not desktop readback.
        HDC source=acquire(expected.get());
        const bool copied=dc && source && BitBlt(dc,0,0,width,height,source,0,0,SRCCOPY);
        GdiFlush();
        if (source) release(expected.get());
        if (dc) release(actual.get());
        if (!copied) throw std::runtime_error("Cannot validate direct frame output");
        const auto* a=pixels(actual.get()); const auto* b=pixels(expected.get());
        const int ap=stride(actual.get()),bp=stride(expected.get());
        RECT dc_clip{}; GetClipBox(target,&dc_clip);
        for (int y=0;y<height;++y) for (int x=0;x<width;++x)
            if (std::memcmp(a+ptrdiff_t(y)*ap+x*4,b+ptrdiff_t(y)*bp+x*4,3))
                throw std::runtime_error("Direct output RGB differs at "+std::to_string(x)+","+std::to_string(y)+
                    " actual="+std::to_string(*reinterpret_cast<const DWORD*>(a+ptrdiff_t(y)*ap+x*4))+
                    " expected="+std::to_string(*reinterpret_cast<const DWORD*>(b+ptrdiff_t(y)*bp+x*4))+
                    " DC="+std::to_string(GetDeviceCaps(target,HORZRES))+"x"+std::to_string(GetDeviceCaps(target,VERTRES))+
                    " clip="+std::to_string(dc_clip.left)+","+std::to_string(dc_clip.top)+","+std::to_string(dc_clip.right)+","+std::to_string(dc_clip.bottom));
        ++direct_checks;
    } catch (const std::exception& error) {
        const std::string diagnostic=error.what();
        renderer::service::set_mode(0);
        direct_output_requested=direct_output_ready=false;
        frames.error=diagnostic;
        mod_loader->log_warning("Direct output validation failed: {}",diagnostic);
    }
}
void end_snapshot_presentation(HDC target,int left,int top,int result) {
    presentation_active=false;
    if (!frames.validation || !strip_ready || !strip_canvas || !target || !result || strip_checks>=6) return;
    try {
        const int width=strip_canvas->info.bitmap->bmiHeader.biWidth;
        const int height=strip_canvas->info.bitmap->bmiHeader.biHeight;
        auto actual=make_surface(width,height);
        if (!BitBlt(actual->dc,0,0,width,height,target,left,top,SRCCOPY))
            throw std::runtime_error("Cannot read assembled strip frame for validation");
        GdiFlush();
        auto* a=pixels(actual.get()); const auto* b=pixels(strip_canvas.get());
        const int ap=stride(actual.get()), bp=stride(strip_canvas.get());
        for (int y=0;y<height;++y) for (int x=0;x<width;++x)
            if (std::memcmp(a+ptrdiff_t(y)*ap+x*4,b+ptrdiff_t(y)*bp+x*4,3))
                throw std::runtime_error("Assembled strip pixels differ from the full frame");
        ++strip_checks;
    } catch (const std::exception& error) {
        frames.error=error.what(); frames.mode=0;
        discard_worker(); snapshot.reset(); frames.presented.reset();
        strip_canvas.reset(); strip_ready=false;
        delete worker_queue; worker_queue=nullptr;
        renderer::reset_raster_workers();
        clear_surface_cache(); rotation_scratch.reset();
        mod_loader->log_warning("Parallel renderer validation failed: {}",frames.error);
    }
}

bool render_snapshot_frame(Screen* screen,Surface* dest,int x,int y,RECT* rect) {
    if (!frames.mode || GetCurrentThreadId()!=owner_thread) return false;
    const auto& full=screen->rect;
    const int width=full.right-full.left, height=full.bottom-full.top;
    const auto& info=dest->info.bitmap->bmiHeader;
    const bool partial=rect && (std::memcmp(rect,&full,sizeof(RECT)) ||
        info.biWidth!=width || info.biHeight!=height);
    if (!partial) return render_snapshot_full_frame(screen,dest,x,y,rect);
    if (!presentation_active || x || y) return false;
    try {
        if (!strip_checked) {
            strip_checked=true;
            if (!strip_canvas || strip_canvas->info.bitmap->bmiHeader.biWidth!=width ||
                strip_canvas->info.bitmap->bmiHeader.biHeight!=height) {
                strip_canvas.reset();
                strip_canvas=make_surface(width,height);
                auto* data=pixels(strip_canvas.get());
                const int pitch=stride(strip_canvas.get());
                for (int row=0;row<height;++row) std::memset(data+ptrdiff_t(row)*pitch,0,size_t(width)*4);
            }
            strip_ready=render_snapshot_full_frame(screen,strip_canvas.get(),0,0,&screen->rect);
            if (strip_ready) ++strip_frames;
        }
        if (!strip_ready) return false;
        const int left=rect->left-full.left, top=rect->top-full.top;
        const int w=rect->right-rect->left, h=rect->bottom-rect->top;
        if (left<0 || top<0 || w<0 || h<0 || left+w>width || top+h>height ||
            w>info.biWidth || h>info.biHeight) return false;
        invalidate_surface(dest);
        const auto copy_start=Clock::now();
        auto* out=pixels(dest);
        const auto* source=pixels(strip_canvas.get());
        const int pitch=stride(dest), source_pitch=stride(strip_canvas.get());
        for (int row=0;row<h;++row)
            std::memcpy(out+ptrdiff_t(row)*pitch,source+ptrdiff_t(top+row)*source_pitch+size_t(left)*4,size_t(w)*4);
        ++strip_copies;
        frames.copy_ms+=elapsed(copy_start);
        return true;
    } catch (const std::exception& error) {
        frames.error=error.what();
        const bool capacity=dynamic_cast<const SnapshotCapacity*>(&error)!=nullptr;
        frames.capacity_fallback=frames.fallback=capacity && (frames.mode==2 || frames.mode==3);
        if (frames.fallback) {
            ++frames.fallbacks;
            frames.retry_at=Clock::now()+std::chrono::milliseconds(frames.capacity_backoff_ms);
            frames.capacity_backoff_ms=(std::min)(frames.capacity_backoff_ms*2u,2000u);
        } else {
            frames.mode=0;
            mod_loader->log_warning("Parallel renderer disabled: {}",frames.error);
        }
        discard_worker(); snapshot.reset(); frames.presented.reset(); strip_canvas.reset();
        delete worker_queue; worker_queue=nullptr;
        renderer::reset_raster_workers();
        clear_surface_cache(); rotation_scratch.reset();
        return false;
    }
}

RenderFrameCounters render_frame_counters() {
    return {frames.mode, frames.collects, frames.skipped, frames.repeats,
            frames.fallbacks, frames.intervals, frames.interval_ms,
            frames.submit_ms, frames.copy_ms, frames.wait_ms, frames.worker_ms};
}

void finish_parallel_renderer() {
    reset_render_integration();
    reset_steam_overlay_frame();
    last_borrowed_surface=nullptr;
    last_screen_frame.reset(); last_live_canvas.reset(); last_frame_valid=false;
    reset_map_frame_probe();
    frames.mode=0;
    frames.fallback=false;
    frames.capacity_fallback=false; frames.retry_at={}; frames.capacity_backoff_ms=100;
    rotation_scratch.reset();
    frames.presented.reset();
    strip_canvas.reset(); strip_checked=strip_ready=false; presentation_active=false;
    delete worker_queue; worker_queue = nullptr; snapshot.reset(); clear_surface_cache();
    renderer::reset_raster_workers();
}


void begin_last_frame_presentation() {
    last_borrowed_surface=nullptr;
    last_frame_valid=false;
    last_frame_rows=0;
}

void preserve_last_frame_before_render() {
    if (!last_frame_valid || !last_borrowed_surface || GetCurrentThreadId()!=owner_thread) return;
    try {
        const auto start=Clock::now();
        const auto& info=last_borrowed_surface->info.bitmap->bmiHeader;
        const int w=info.biWidth,h=info.biHeight;
        last_live_canvas=make_surface(w,h);
        auto* out=pixels(last_live_canvas.get()); const auto* in=pixels(last_borrowed_surface);
        const int op=stride(last_live_canvas.get()),ip=stride(last_borrowed_surface);
        for (int row=0;row<h;++row)
            std::memcpy(out+ptrdiff_t(row)*op,in+ptrdiff_t(row)*ip,size_t(w)*4);
        last_screen_frame=last_live_canvas;
        last_borrowed_surface=nullptr;
        ++last_frame_copies; last_frame_capture_ms+=elapsed(start);
    } catch (const std::exception&) {
        last_borrowed_surface=nullptr; last_frame_valid=false;
        last_screen_frame.reset(); last_live_canvas.reset();
    }
}

void remember_screen_frame(Screen* screen,Surface* source,int x,int y,RECT* rect,bool parallel) {
    if (!last_frame_enabled || !renderer::surface_resources_ready() || GetCurrentThreadId()!=owner_thread ||
        screen!=(*rgss_game)->screen || x || y) return;
    try {
        const auto& full=screen->rect;
        const int w=full.right-full.left, h=full.bottom-full.top;
        const RECT region=rect ? *rect : full;
        if (region.left!=full.left || region.right!=full.right ||
            region.top-full.top!=last_frame_rows || region.bottom>full.bottom) return;
        const int rows=region.bottom-region.top;
        if (rows<=0) return;
        if (parallel && strip_ready && strip_canvas) {
            last_screen_frame=strip_canvas;
            last_live_canvas.reset();
        } else if (parallel && frames.presented && rows==h) {
            last_screen_frame=frames.presented;
            last_live_canvas.reset();
        } else if (source==screen->surface && rows==h &&
                   source->info.bitmap->bmiHeader.biWidth==w &&
                   source->info.bitmap->bmiHeader.biHeight==h) {
            // The engine owns this persistent full-screen buffer. Its lifecycle
            // and mutation hooks invalidate the borrow; readback owns only its copy.
            last_screen_frame.reset(); last_live_canvas.reset();
            last_borrowed_surface=source;
        } else {
            const auto start=Clock::now();
            const auto& info=source->info.bitmap->bmiHeader;
            if (info.biWidth<w || info.biHeight<rows) return;
            if (!last_live_canvas || last_live_canvas->info.bitmap->bmiHeader.biWidth!=w ||
                last_live_canvas->info.bitmap->bmiHeader.biHeight!=h) {
                last_screen_frame.reset(); last_live_canvas.reset();
                last_live_canvas=make_surface(w,h);
            }
            auto* out=pixels(last_live_canvas.get());
            const auto* in=pixels(source);
            const int op=stride(last_live_canvas.get()), ip=stride(source);
            for (int row=0;row<rows;++row)
                std::memcpy(out+ptrdiff_t(last_frame_rows+row)*op,in+ptrdiff_t(row)*ip,size_t(w)*4);
            last_screen_frame=last_live_canvas;
            ++last_frame_copies;
            last_frame_capture_ms+=elapsed(start);
        }
        last_frame_rows+=rows;
    } catch (const std::exception&) {
        last_borrowed_surface=nullptr;
        last_screen_frame.reset(); last_live_canvas.reset(); last_frame_rows=-1;
    }
}

void end_last_frame_presentation(int result) {
    if (!last_frame_enabled || !*rgss_game || !(*rgss_game)->screen) return;
    const auto& full=(*rgss_game)->screen->rect;
    last_frame_valid=result && (last_screen_frame || last_borrowed_surface) && last_frame_rows==full.bottom-full.top;
    if (!last_frame_valid) { last_screen_frame.reset(); last_borrowed_surface=nullptr; }
}

void renderer::service::install() {
    const auto* fast = mod_loader->get_config().get("fast_render");
    if (fast && fast->get<bool>()) {
        return;
    }
    static_assert(sizeof(void*) == 4);
    static_assert(offsetof(Sprite, child_begin) == 0x84);
    static_assert(offsetof(Sprite, child_end) == 0x88);
    // RGSS301 is enforced by the loader. The walker may already be detoured by
    // ViewportEffects; its hook explicitly bypasses live effects during replay.
    renderer::initialize_snapshot_replay();
    renderer::install_raster_workers();
    const auto* hrfix_config=mod_loader->get_config().get("hrfix_enable");
    tilemap_hrfix=hrfix_config && hrfix_config->get<bool>();
    renderer::initialize_surface_resources(tilemap_hrfix);
    // IDA: every standard Bitmap pixel writer except set_pixel calls 0x6100.
    // Hook the native entries, so Ruby aliases also remain covered.
    renderer::install_bitmap_mutation_hooks();
    mod_loader->hook_method(0x10b2d0, &SurfaceTracking::destroy_hook, &SurfaceTracking::original_destroy);
    mod_loader->hook_method(0x10b3b0, &SurfaceTracking::init_hook, &SurfaceTracking::original_init);
    mod_loader->hook_method(0x10b720, &SurfaceTracking::release_dc_hook, &SurfaceTracking::original_release_dc);
    mod_loader->add_preinit_handler([] {
        owner_thread = GetCurrentThreadId();
        finish_parallel_renderer();
        snapshot.reset(); // F12 must release the previous run's owned resources
        last_error.clear();
        api_error_fallback=nullptr;
        capture_ms = draw_ms = 0;
        renderer::register_ruby_bindings();
    });
    mod_loader->log_info("Parallel rendering support ready\n");
}
}
