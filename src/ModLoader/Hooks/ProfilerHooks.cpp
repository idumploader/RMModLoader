#include "ProfilerHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMGlobal.hpp"
#include "../Profiler/Recording.hpp"

#include <nlohmann/json.hpp>
#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <stdexcept>
#include <tuple>
#include <vector>

namespace rm_modloader {
#if defined(_M_IX86)
    namespace {
        using json = nlohmann::json;
        using Callback = void(__cdecl*)(unsigned, RubyValue, RubyValue, RubyID, RubyValue);
        using AddHook = void(__cdecl*)(Callback, unsigned, RubyValue);
        using Mark = void(__cdecl*)(RubyValue);
        using Intern = RubyID(__cdecl*)(const char*);
        using Name = const char*(__cdecl*)(RubyID);
        using Source = const char*(__cdecl*)();
        using Line = int(__cdecl*)();
        using CurrentFiber = RubyValue(__cdecl*)();
        using ForeachCallback = int(__cdecl*)(RubyValue, RubyValue, RubyValue);
        using Foreach = int(__cdecl*)(void*, ForeachCallback, RubyValue);

        AddHook add_hook;
        void* remove_helper;
        Mark mark_value;
        Intern intern;
        Name id_name;
        Source source_file;
        Line source_line;
        CurrentFiber current_fiber;
        Foreach table_foreach;
        ForeachCallback set_vm_flag;
        unsigned** current_thread;
        unsigned** current_vm;
        RubyID ivar_set, inspect_id;
        RubyValue owner_ivar;
        std::array<RubyID, 6> control_ids{};

        uint64_t ticks() noexcept {
            LARGE_INTEGER value;
            QueryPerformanceCounter(&value);
            return static_cast<uint64_t>(value.QuadPart);
        }
        template<class T> T field(const void* p, size_t offset) noexcept {
            return *reinterpret_cast<const T*>(static_cast<const char*>(p) + offset);
        }
        struct Method {
            RubyID id;
            RubyValue klass;
            bool native;
            std::string file;
            int line;
        };
        struct Session {
            std::vector<profiler::Event> events;
            std::vector<Method> methods;
            std::map<std::tuple<RubyID, RubyValue, bool>, uint32_t> method_ids;
            std::set<RubyValue> fibers;
            RubyValue owner = ruby_nil;
            unsigned* thread = nullptr;
            DWORD os_thread = 0;
            size_t limit = 0;
            bool recording = false, attached = false, inside_callback = false;
            uint64_t begin = 0, end = 0, frequency = 0, callback_ticks = 0;
            const char* reason = "not_started";

            void halt(const char* why, uint64_t now) noexcept {
                recording = false;
                end = now;
                reason = why;
            }
        } session;

        struct RubyJump { int state; };
        struct CallArgs { RubyValue receiver; RubyID method; int count; RubyValue a, b; };
        RubyValue __cdecl do_call(RubyValue data) {
            auto* args = reinterpret_cast<CallArgs*>(data);
            return rb_funcall(args->receiver, args->method, args->count, args->a, args->b);
        }
        RubyValue call(RubyValue receiver, RubyID method, int count = 0,
                       RubyValue a = ruby_nil, RubyValue b = ruby_nil) {
            CallArgs args{receiver, method, count, a, b};
            int state = 0;
            const auto value = rb_protect(do_call, reinterpret_cast<RubyValue>(&args), &state);
            if (state) throw RubyJump{state};
            return value;
        }
        // All throwing C++ scopes end before Ruby longjmp is allowed to escape.
        template<class F> RubyValue api(F body) {
            int state = 0;
            char error[512] = {};
            try { return body(); }
            catch (const RubyJump& jump) { state = jump.state; }
            catch (const std::exception& e) {
                strncpy_s(error, e.what(), sizeof(error) - 1);
            }
            catch (...) { strcpy_s(error, "unknown native profiler error"); }
            if (state) rb_jump_tag(state);
            rb_raise(*ruby_error_arg_error, "profiler: %s", error);
            return ruby_nil;
        }

        void __cdecl mark_session(void*) {
            for (const auto& method : session.methods)
                if (method.klass) mark_value(method.klass);
            for (auto fiber : session.fibers) if (fiber) mark_value(fiber);
        }
        void __cdecl keep_session(void*) {} // static C++ storage, not Ruby-owned
        RubyValue __cdecl create_owner(RubyValue) {
            return make_rb_rdata(*ruby_c_object, &session, mark_session, keep_session);
        }

        void require_thread() {
            if (session.os_thread && (GetCurrentThreadId() != session.os_thread ||
                                     *current_thread != session.thread))
                throw std::runtime_error("use the Ruby thread that started the recording");
        }

        // Non-allocating subset of rb_thread_method_id_and_class (RVA 0x02A860).
        // Never intern <ifunc>, invoke Ruby, or allocate a Ruby object in a hook.
        bool method_from_frame(unsigned cfp, RubyID& id, RubyValue& klass) noexcept {
            const auto* frame = reinterpret_cast<const void*>(cfp);
            auto* iseq = field<const unsigned*>(frame, 12);
            if (!iseq) return false;
            for (unsigned depth = 0; iseq && depth < 128; ++depth) {
                if ((iseq[0] & 0x1f) == 0x1c) return false; // internal node/ifunc
                id = field<RubyID>(iseq, 140);
                if (id) { klass = field<RubyValue>(iseq, 136); return true; }
                if (field<const unsigned*>(iseq, 120) == iseq) break;
                iseq = field<const unsigned*>(iseq, 116);
            }
            return false;
        }

        void __cdecl event_hook(unsigned event, RubyValue, RubyValue,
                                RubyID id, RubyValue klass) noexcept {
            auto& s = session;
            if (!s.recording || s.inside_callback || GetCurrentThreadId() != s.os_thread ||
                *current_thread != s.thread) return;
            if ((event == profiler::CCall || event == profiler::CReturn) &&
                std::find(control_ids.begin(), control_ids.end(), id) != control_ids.end()) return;
            s.inside_callback = true;
            const auto now = ticks();
            try {
                if (s.events.size() == s.limit) s.halt("event_limit", now);
                else {
                    const auto cfp = s.thread[4];
                    const auto fiber = s.thread[73];
                    if (!fiber) s.halt("missing_fiber", now);
                    else {
                        if (s.fibers.size() >= 4096 && !s.fibers.count(fiber))
                            s.halt("context_limit", now);
                        else {
                            s.fibers.insert(fiber);
                            const bool native = event == profiler::CCall || event == profiler::CReturn;
                            uint32_t method = 0;
                            if (event != profiler::Raise) {
                                if (!native) { id = 0; klass = 0; method_from_frame(cfp, id, klass); }
                                // T_ICLASS is 0x1D in this binary, independently of Ruby.hpp.
                                if (klass != 0 && klass != ruby_nil && (klass & 3) == 0 &&
                                    (field<unsigned>(reinterpret_cast<void*>(klass), 0) & 0x1f) == 0x1d)
                                    klass = field<RubyValue>(reinterpret_cast<void*>(klass), 4);
                                if (id && klass != 0 && klass != ruby_nil && (klass & 3) == 0) {
                                    const auto key = std::make_tuple(id, klass, native);
                                    auto found = s.method_ids.find(key);
                                    if (found != s.method_ids.end()) method = found->second;
                                    else if (s.methods.size() >= 16384) s.halt("method_limit", now);
                                    else {
                                        const char* file = native ? nullptr : source_file();
                                        method = static_cast<uint32_t>(s.methods.size());
                                        s.methods.push_back({id, klass, native,
                                            file ? std::string(file, strnlen(file, 4096)) : "",
                                            native ? 0 : source_line()});
                                        s.method_ids.emplace(key, method);
                                    }
                                }
                            }
                            if (s.recording) s.events.push_back({now, fiber, method, cfp, event});
                        }
                    }
                }
            } catch (...) { s.halt("allocation_failure", now); }
            s.callback_ticks += ticks() - now;
            s.inside_callback = false;
        }

        void detach() {
            if (!session.attached) return;
            require_thread();
            if (session.inside_callback) throw std::runtime_error("cannot stop inside an event callback");
            auto** head = reinterpret_cast<void**>(reinterpret_cast<char*>(*current_vm) + 0x114);
            void* helper = remove_helper;
            Callback callback = event_hook;
            // The internal removal helper uses EBX, NOT cdecl(callback).
            __asm {
                push ebx
                mov ebx, callback
                push head
                call helper
                add esp, 4
                pop ebx
            }
            session.attached = false;
            if (!*head) table_foreach(reinterpret_cast<void*>((*current_vm)[9]), set_vm_flag, 0);
        }
        void stop(const char* reason) {
            require_thread();
            if (session.recording) session.halt(reason, ticks());
            detach();
        }

        RubyValue __cdecl start(RubyValue self, RubyValue limit_value) {
            return api([&]() -> RubyValue {
                require_thread();
                if (session.attached) throw std::runtime_error("stop the current recording first");
                if ((limit_value & 1) == 0) throw std::runtime_error("event limit must be an Integer");
                const auto limit = static_cast<int32_t>(limit_value) >> 1;
                if (limit < 1024 || limit > 2000000)
                    throw std::runtime_error("event limit must be between 1024 and 2000000");
                // Reserve before replacing the previous recording; a failed
                // allocation must not leave a partially active profiler.
                std::vector<profiler::Event> events;
                events.reserve(static_cast<size_t>(limit));
                if (session.owner == ruby_nil) {
                    int state = 0;
                    session.owner = rb_protect(create_owner, ruby_nil, &state);
                    if (state) throw RubyJump{state};
                }
                call(self, ivar_set, 2, owner_ivar, session.owner);
                // The root Fiber can be lazily allocated; do that before tracing.
                int state = 0;
                rb_protect([](RubyValue) -> RubyValue { return current_fiber(); }, ruby_nil, &state);
                if (state) throw RubyJump{state};
                session.events.swap(events);
                session.methods.clear(); session.method_ids.clear(); session.fibers.clear();
                session.methods.push_back({0, 0, false, "", 0});
                session.thread = *current_thread;
                session.os_thread = GetCurrentThreadId();
                session.limit = static_cast<size_t>(limit);
                LARGE_INTEGER frequency;
                QueryPerformanceFrequency(&frequency);
                session.frequency = static_cast<uint64_t>(frequency.QuadPart);
                session.callback_ticks = 0;
                session.reason = "recording";
                // Allocation in registration is protected before any active flag.
                rb_protect([](RubyValue) -> RubyValue {
                    add_hook(event_hook, 0xf8, session.owner);
                    return ruby_nil;
                }, ruby_nil, &state);
                if (state) throw RubyJump{state};
                session.attached = true;
                session.begin = session.end = ticks();
                session.recording = true;
                return ruby_true;
            });
        }
        RubyValue __cdecl stop_api(RubyValue) {
            return api([]() -> RubyValue { stop("manual"); return ruby_nil; });
        }
        RubyValue __cdecl frame_api(RubyValue) {
            return api([]() -> RubyValue {
                require_thread();
                if (session.recording) {
                    const auto now = ticks();
                    if (session.events.size() == session.limit) session.halt("event_limit", now);
                    else session.events.push_back({now, session.thread[73], 0,
                                                   session.thread[4], profiler::Frame});
                }
                // Called by Ruby AFTER Graphics.update, outside event dispatch.
                if (!session.recording) detach();
                return session.recording ? ruby_true : ruby_false;
            });
        }
        RubyValue __cdecl recording_api(RubyValue) {
            return session.recording ? ruby_true : ruby_false;
        }
        RubyValue __cdecl discard_api(RubyValue) {
            return api([]() -> RubyValue {
                stop("discarded");
                std::vector<profiler::Event>().swap(session.events);
                std::vector<Method>().swap(session.methods);
                session.method_ids.clear(); session.fibers.clear();
                session.begin = session.end = 0;
                return ruby_nil;
            });
        }

        std::string ruby_text(RubyValue value) {
            if ((value & 3) || value == 0 || value == 4) return "<non-string>";
            const auto* str = reinterpret_cast<const unsigned*>(value);
            if ((str[0] & 0x1f) != 5) return "<non-string>";
            // Correct embedded-string length (Ruby.hpp's generic helper is
            // intentionally not used here). MRI 1.9.2 RSTRING_NOEMBED = 0x2000.
            const bool heap = (str[0] & 0x2000) != 0;
            const char* ptr = heap ? reinterpret_cast<const char*>(str[3]) : reinterpret_cast<const char*>(str + 2);
            const size_t size = heap ? str[2] : ((str[0] >> 14) & 0x1f);
            return std::string(ptr, size);
        }
        std::string dump(const json& value) {
            return value.dump(-1, ' ', false, json::error_handler_t::replace);
        }
        RubyValue __cdecl method_name_string(RubyValue id) {
            const char* name = id_name(id);
            return rb_str_new_cstr(name ? name : "<unknown>");
        }
        RubyValue __cdecl save_api(RubyValue, RubyValue path_value) {
            return api([&]() -> RubyValue {
                stop("manual");
                if (!session.begin) throw std::runtime_error("no recording to save");
                if ((path_value & 3) || path_value == 0 || path_value == 4 ||
                    (field<unsigned>(reinterpret_cast<void*>(path_value), 0) & 0x1f) != 5)
                    throw std::runtime_error("path must be a String");
                const auto path_text = ruby_text(path_value);
                if (path_text.empty() || path_text.find('\0') != std::string::npos)
                    throw std::runtime_error("invalid output path");
                const auto path = std::filesystem::u8path(path_text);
                // Never truncate an existing report, including on a repeated save.
                if (std::filesystem::exists(path)) throw std::runtime_error("output file already exists");
                auto temporary = path;
                temporary += ".partial";
                if (std::filesystem::exists(temporary)) throw std::runtime_error("partial output file already exists");
                const auto summary = profiler::summarize(session.events, session.methods.size(),
                                                          session.begin, session.end);
                auto ms = [&](uint64_t value) { return value * 1000.0 / session.frequency; };
                std::ofstream out(temporary, std::ios::binary);
                if (!out) throw std::runtime_error("cannot create output file (directory must exist)");
                out.exceptions(std::ios::badbit | std::ios::failbit);
                json meta = {{"schema", "rgss-native-profiler-v1"}, {"clock", "wall_qpc"},
                    {"duration_ms", ms(session.end - session.begin)}, {"stop_reason", session.reason},
                    {"event_count", session.events.size()}, {"event_limit", session.limit},
                    {"callback_ms", ms(session.callback_ticks)}, {"unattributed_ms", ms(summary.unattributed)},
                    {"unmatched_returns", summary.unmatched_returns}, {"raises", summary.raises},
                    {"context_changes", summary.context_changes},
                    {"limitations", {"Fiber switches are inferred at observed event boundaries",
                        "Only the initiating Ruby thread is collected; wall time includes waits",
                        "Graphics.update includes both rendering and waiting",
                        "Trace/GC overhead is included; callback_ms is only part of that overhead",
                        "Recording can start/end mid-call; inspect unwound and unmatched_returns"}},
                    {"event_columns", {"us", "kind", "fiber", "method", "cfp"}}};
                out << "{\"meta\":" << dump(meta) << ",\"methods\":[";
                for (size_t i = 0; i < session.methods.size(); ++i) {
                    const auto& method = session.methods[i];
                    std::string label = "<unresolved>";
                    if (method.klass) {
                        // Protected Ruby calls preserve C++ stream/container
                        // lifetimes if a custom inspect method raises.
                        label = ruby_text(call(method.klass, inspect_id));
                        int state = 0;
                        const auto name = rb_protect(method_name_string, method.id, &state);
                        if (state) throw RubyJump{state};
                        label += "#";
                        label += ruby_text(name);
                    }
                    const auto& stats = summary.methods[i];
                    json item = {{"id", i}, {"name", label}, {"native", method.native},
                        {"file", method.file}, {"first_observed_line", method.line},
                        {"self_ms", ms(stats.self)}, {"total_ms", ms(stats.total)},
                        {"calls", stats.calls}, {"completed", stats.completed},
                        {"unwound", stats.unwound}, {"open_at_stop", stats.open_at_stop}};
                    if (i) out << ',';
                    out << dump(item);
                }
                out << "],\"frames\":[";
                for (size_t i = 0; i < summary.frames.size(); ++i) {
                    const auto& frame = summary.frames[i];
                    if (i) out << ',';
                    out << dump(json{{"start_ms", ms(frame.begin - session.begin)},
                        {"duration_ms", ms(frame.end - frame.begin)}, {"partial", frame.partial}});
                }
                out << "],\"events\":[";
                for (size_t i = 0; i < session.events.size(); ++i) {
                    const auto& event = session.events[i];
                    if (i) out << ',';
                    out << dump(json::array({ms(event.tick - session.begin) * 1000.0,
                        event.kind, event.context, event.method, event.cfp}));
                }
                out << "]}\n";
                out.close();
                // Windows rename fails if destination appeared while writing.
                std::filesystem::rename(temporary, path);
                return ruby_true;
            });
        }

        bool matches(ptrdiff_t rva, std::initializer_list<unsigned char> bytes) {
            return std::memcmp(at_offset<const void*>(rgss_module, rva), bytes.begin(), bytes.size()) == 0;
        }
        bool bind_runtime() {
            // Fail closed on a different runtime layout. Patterns contain no
            // absolute relocated addresses; version guard is also applied by RMGlobal.
            if (!matches(0x0930f0, {0x6a,0x10,0xe8,0xc9,0x5f,0xfc,0xff}) ||
                !matches(0x093150, {0x55,0x8b,0x6c,0x24,0x08,0x8b,0x45,0x00}) ||
                !matches(0x02a860, {0x8b,0x44,0x24,0x04,0x8b,0x48,0x10,0x8b,0x41,0x0c}) ||
                !matches(0x048650, {0x8b,0x44,0x24,0x04,0x50,0xe8,0x46,0xfe,0xff,0xff}) ||
                !matches(0x058690, {0x53,0x8b,0x5c,0x24,0x08,0xf6,0xc3,0x03})) return false;
            add_hook = at_offset<AddHook>(rgss_module, 0x0930f0);
            remove_helper = at_offset<void*>(rgss_module, 0x093150);
            mark_value = at_offset<Mark>(rgss_module, 0x058690);
            intern = at_offset<Intern>(rgss_module, 0x048400);
            id_name = at_offset<Name>(rgss_module, 0x048650);
            source_file = at_offset<Source>(rgss_module, 0x02a130);
            source_line = at_offset<Line>(rgss_module, 0x02a180);
            current_fiber = at_offset<CurrentFiber>(rgss_module, 0x0dc3b0);
            table_foreach = at_offset<Foreach>(rgss_module, 0x088240);
            set_vm_flag = at_offset<ForeachCallback>(rgss_module, 0x092ff0);
            current_thread = at_offset<unsigned**>(rgss_module, 0x270310);
            current_vm = at_offset<unsigned**>(rgss_module, 0x270314);
            return true;
        }
    }
#endif

    void apply_profiler_hooks() {
#if defined(_M_IX86)
        if (!bind_runtime()) {
            mod_loader->log_error("Native profiler unavailable: RGSS byte checks failed\n");
            return;
        }
        mod_loader->add_preinit_handler([] {
            ivar_set = intern("instance_variable_set");
            inspect_id = intern("inspect");
            owner_ivar = (intern("@__native_profiler_owner") << 8) | 0x0e;
            const char* names[] = {"profiler_start", "profiler_stop", "profiler_frame",
                                  "profiler_recording?", "profiler_discard", "profiler_save"};
            for (size_t i = 0; i < control_ids.size(); ++i) control_ids[i] = intern(names[i]);
            mod_loader->register_ruby_method(names[0], start);
            mod_loader->register_ruby_method(names[1], stop_api);
            mod_loader->register_ruby_method(names[2], frame_api);
            mod_loader->register_ruby_method(names[3], recording_api);
            mod_loader->register_ruby_method(names[4], discard_api);
            mod_loader->register_ruby_method(names[5], save_api);
        });
#endif
    }
}
