#include "RubyBindings.hpp"
#include "RendererService.hpp"
#include "../ParallelRenderer.hpp"
#include "../SteamOverlayHooks.hpp"
#include "../../ModLoader.hpp"
#include "../../RMGlobal.hpp"
#include "../../Hook.hpp"
#include <stdexcept>
#include <string>

namespace rm_modloader::renderer {
namespace {
    RubyValue viewport_class,bitmap_class;
    struct RubyJump { int state; };
    struct IntegerArgs { RubyValue value; int result=0; };
    RubyValue __cdecl parse_integer_call(RubyValue data) {
        auto& args=*reinterpret_cast<IntegerArgs*>(data);
        args.result=rb_parse_int(args.value);
        return ruby_nil;
    }
    int parse_integer(RubyValue value) {
        IntegerArgs args{value};
        int state=0;
        rb_protect(parse_integer_call,reinterpret_cast<RubyValue>(&args),&state);
        if (state) throw RubyJump{state};
        return args.result;
    }
    struct StringArgs { const char* data; long length; };
    RubyValue __cdecl create_string_call(RubyValue data) {
        auto& args=*reinterpret_cast<StringArgs*>(data);
        return rb_str_new(args.data,args.length);
    }
    RubyValue ruby_string(const std::string& text) {
        StringArgs args{text.data(),static_cast<long>(text.size())};
        int state=0;
        const auto value=rb_protect(create_string_call,reinterpret_cast<RubyValue>(&args),&state);
        if (state) throw RubyJump{state};
        return value;
    }
    // Ruby conversion/allocation is protected. Ruby jumps become C++ unwinding
    // first; jump_tag runs only after strings and throwing C++ scopes have ended.
    template<class F> RubyValue boundary(F action) {
        int state=0;
        try { return action(); }
        catch (const RubyJump& jump) { state=jump.state; }
        catch (const std::exception& error) { service::set_api_error(error.what()); return ruby_false; }
        if (state) rb_jump_tag(state);
        return ruby_false;
    }
    template<class F> RubyValue attempt(F action,bool allow_frame_mode=false) {
        return boundary([&] {
            service::begin_api_operation(allow_frame_mode);
            action();
            return ruby_true;
        });
    }
    template<class T> T* native(RubyValue value,RubyValue klass) {
        // Exact RGSS classes only: arbitrary T_DATA has no known native layout.
        if (rb_type(value)!=RUBY_T_DATA || reinterpret_cast<RubyRBasic*>(value)->klass!=klass)
            throw std::runtime_error("Expected an exact native Viewport/Bitmap instance");
        auto* wrapper=get_rb_data_data<unsigned char>(value);
        if (!wrapper || !at_address<T*>(wrapper,8))
            throw std::runtime_error("Object has no live native resource");
        return at_address<T*>(wrapper,8);
    }
    Sprite* root(RubyValue viewport) {
        if (viewport==ruby_nil) return service::screen_root();
        auto* result=native<RxViewport>(viewport,viewport_class);
        if (at_address<DWORD>(result,0xcc)) throw std::runtime_error("Viewport is disposed");
        return result;
    }
    RubyValue __cdecl frame_mode_api(RubyValue,RubyValue value) {
        return attempt([&] { service::set_mode(parse_integer(value)); },true);
    }
    RubyValue __cdecl pixel_limit_get_api(RubyValue) { return rb_make_number(service::memory_limit()); }
    RubyValue __cdecl pixel_limit_set_api(RubyValue,RubyValue value) {
        return attempt([&] { service::set_memory_limit(parse_integer(value)); },true);
    }
    RubyValue __cdecl frame_status_api(RubyValue) {
        return boundary([] { return ruby_string(service::frame_status()); });
    }
    RubyValue __cdecl status_api(RubyValue) {
        return boundary([] { return ruby_string(service::status()); });
    }
    RubyValue __cdecl start_api(RubyValue,RubyValue bitmap,RubyValue count) {
        return attempt([&] {
            const int repeats=parse_integer(count);
            auto* source=native<Surface>(bitmap,bitmap_class);
            service::start(source,repeats);
        });
    }
    RubyValue __cdecl submit_api(RubyValue,RubyValue viewport,RubyValue bitmap,RubyValue count) {
        return attempt([&] {
            const int repeats=parse_integer(count);
            auto* source=native<Surface>(bitmap,bitmap_class);
            auto* source_root=root(viewport);
            service::submit(source_root,viewport!=ruby_nil,source,repeats);
        });
    }
    RubyValue __cdecl collect_api(RubyValue,RubyValue bitmap) {
        return attempt([&] { service::collect(native<Surface>(bitmap,bitmap_class)); });
    }
    RubyValue __cdecl capture_api(RubyValue,RubyValue viewport) {
        return attempt([&] {
            // Failed capture must invalidate an earlier snapshot, including a
            // failure while decoding a disposed or unsupported root.
            service::clear();
            service::capture(root(viewport),viewport!=ruby_nil);
        });
    }
    RubyValue __cdecl draw_api(RubyValue,RubyValue bitmap) {
        return attempt([&] { service::draw_snapshot(native<Surface>(bitmap,bitmap_class)); });
    }
    RubyValue __cdecl reference_api(RubyValue,RubyValue viewport,RubyValue bitmap) {
        return attempt([&] {
            auto* source_root=root(viewport);
            auto* destination=native<Surface>(bitmap,bitmap_class);
            service::reference(source_root,viewport!=ruby_nil,destination);
        });
    }
    RubyValue __cdecl clear_api(RubyValue) { return attempt([] { service::clear(); }); }
    RubyValue benchmark_api(RubyValue viewport,RubyValue bitmap,RubyValue count,bool snapshot) {
        return attempt([&] {
            const int frames=parse_integer(count);
            auto* source_root=root(viewport);
            auto* destination=native<Surface>(bitmap,bitmap_class);
            service::benchmark(source_root,viewport!=ruby_nil,destination,frames,snapshot);
        });
    }
    RubyValue __cdecl original_benchmark_api(RubyValue,RubyValue vp,RubyValue bitmap,RubyValue count) {
        return benchmark_api(vp,bitmap,count,false);
    }
    RubyValue __cdecl snapshot_benchmark_api(RubyValue,RubyValue vp,RubyValue bitmap,RubyValue count) {
        return benchmark_api(vp,bitmap,count,true);
    }
    RubyValue __cdecl optimization_api(RubyValue,RubyValue value) {
        return attempt([&] { service::set_optimization(parse_integer(value)); });
    }
    RubyValue __cdecl invalidate_api(RubyValue,RubyValue bitmap) {
        return attempt([&] { service::invalidate(native<Surface>(bitmap,bitmap_class)); });
    }
    RubyValue __cdecl pixels_equal_api(RubyValue,RubyValue a,RubyValue b) {
        bool equal=false;
        const auto ok=attempt([&] {
            auto* left=native<Surface>(a,bitmap_class);
            auto* right=native<Surface>(b,bitmap_class);
            equal=service::pixels_equal(left,right);
        },true);
        return ok==ruby_true && equal ? ruby_true : ruby_false;
    }
    template<typename R,typename... A>
    void register_renderer_api(std::string_view legacy,R(__cdecl* function)(RubyValue,A...)) {
        std::string name="parallel_renderer";
        name+=legacy.substr(std::string_view("render_snapshot_probe").size());
        const auto pixel=name.find("pixel_limit");
        if (pixel!=std::string::npos) name.replace(pixel,11,"memory_limit");
        mod_loader->register_ruby_method(name,function);
        mod_loader->register_ruby_method(legacy,function);
    }
    BOOL (__cdecl* original_bitmap_changed)(void*);
    BOOL __cdecl bitmap_changed(void* wrapper) {
        service::notify_bitmap_changed(at_address<Surface*>(wrapper,8));
        return original_bitmap_changed(wrapper);
    }
    RubyValue (__cdecl* original_set_pixel)(RubyValue,RubyValue,RubyValue,RubyValue);
    RubyValue __cdecl set_pixel_hook(RubyValue self,RubyValue x,RubyValue y,RubyValue color) {
        auto* wrapper=get_rb_data_data<unsigned char>(self);
        if (wrapper) service::notify_bitmap_changed(at_address<Surface*>(wrapper,8));
        return original_set_pixel(self,x,y,color);
    }
}
void install_bitmap_mutation_hooks() {
    mod_loader->hook_function(0x6100,&bitmap_changed,&original_bitmap_changed);
    mod_loader->hook_function(0x6a90,&set_pixel_hook,&original_set_pixel);
}
void register_ruby_bindings() {
    viewport_class=eval_rb_cstr_noerr("Viewport");
    bitmap_class=eval_rb_cstr_noerr("Bitmap");
    mod_loader->register_ruby_method("last_frame_enable",+[](RubyValue,RubyValue enabled) -> RubyValue {
        return attempt([&] { service::enable_last_frame(enabled==ruby_true); },true);
    });
    mod_loader->register_ruby_method("last_frame_copy",+[](RubyValue,RubyValue bitmap) -> RubyValue {
        if (!service::last_frame_ready()) return ruby_false;
        return attempt([&] { service::copy_last_frame(native<Surface>(bitmap,bitmap_class)); },true);
    });
    mod_loader->register_ruby_method("last_frame_status",+[](RubyValue) -> RubyValue {
        return boundary([] { return ruby_string(service::last_frame_status()); });
    });
    register_renderer_api("render_snapshot_probe_capture",capture_api);
    register_renderer_api("render_snapshot_probe_draw",draw_api);
    register_renderer_api("render_snapshot_probe_reference",reference_api);
    register_renderer_api("render_snapshot_probe_clear",clear_api);
    register_renderer_api("render_snapshot_probe_status",status_api);
    register_renderer_api("render_snapshot_probe_start",start_api);
    register_renderer_api("render_snapshot_probe_collect",collect_api);
    register_renderer_api("render_snapshot_probe_submit",submit_api);
    register_renderer_api("render_snapshot_probe_optimization",optimization_api);
    register_renderer_api("render_snapshot_probe_invalidate",invalidate_api);
    register_renderer_api("render_snapshot_probe_pixels_equal",pixels_equal_api);
    register_renderer_api("render_snapshot_probe_snapshot_benchmark",snapshot_benchmark_api);
    register_renderer_api("render_snapshot_probe_original_benchmark",original_benchmark_api);
    register_renderer_api("render_snapshot_probe_frame_mode",frame_mode_api);
    register_renderer_api("render_snapshot_probe_frame_status",frame_status_api);
    mod_loader->register_ruby_method("parallel_renderer_current_mode",+[](RubyValue) -> RubyValue {
        return rb_make_number(service::current_mode());
    });
    mod_loader->register_ruby_method("parallel_renderer_workers",+[](RubyValue) -> RubyValue {
        return rb_make_number(service::workers());
    });
    mod_loader->register_ruby_method("steam_overlay_set_optimizations",+[](RubyValue,RubyValue value) -> RubyValue {
        return attempt([&] { configure_steam_overlay_optimizations(parse_integer(value)); },true);
    });
    mod_loader->register_ruby_method("steam_overlay_optimizations",+[](RubyValue) -> RubyValue {
        return rb_make_number(steam_overlay_optimizations());
    });
    mod_loader->register_ruby_method("parallel_renderer_direct_output",+[](RubyValue) -> RubyValue {
        return service::direct_output() ? ruby_true : ruby_false;
    });
    mod_loader->register_ruby_method("parallel_renderer_set_parallel_stretch",+[](RubyValue,RubyValue value) -> RubyValue {
        return attempt([&] { service::set_parallel_stretch(value==ruby_true); },true);
    });
    mod_loader->register_ruby_method("parallel_renderer_parallel_stretch",+[](RubyValue) -> RubyValue {
        return service::parallel_stretch() ? ruby_true : ruby_false;
    });
    mod_loader->register_ruby_method("parallel_renderer_set_direct_output",+[](RubyValue,RubyValue value) -> RubyValue {
        return attempt([&] { service::set_direct_output(value==ruby_true); },true);
    });
    mod_loader->register_ruby_method("parallel_renderer_set_workers",+[](RubyValue,RubyValue value) -> RubyValue {
        return attempt([&] { service::set_workers(parse_integer(value)); },true);
    });
    mod_loader->register_ruby_method("parallel_renderer_last_error",+[](RubyValue) -> RubyValue {
        return boundary([] { return ruby_string(service::frame_error()); });
    });
    mod_loader->register_ruby_method("parallel_renderer_health",+[](RubyValue) -> RubyValue {
        return rb_make_number(service::health());
    });
    mod_loader->register_ruby_method("parallel_renderer_validation",+[](RubyValue,RubyValue enabled) -> RubyValue {
        return attempt([&] { service::set_validation(enabled==ruby_true); },true);
    });
    register_renderer_api("render_snapshot_probe_pixel_limit_mib",pixel_limit_get_api);
    register_renderer_api("render_snapshot_probe_set_pixel_limit_mib",pixel_limit_set_api);
    register_renderer_api("render_snapshot_probe_frame_barrier",+[](RubyValue) -> RubyValue {
        return attempt([] { service::barrier(); },true);
    });
    register_renderer_api("render_snapshot_probe_finish",+[](RubyValue) -> RubyValue {
        return attempt([] { finish_parallel_renderer(); },true);
    });
}
}
