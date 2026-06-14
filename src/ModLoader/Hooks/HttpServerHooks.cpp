// httplib brings <winsock2.h>; it MUST come before any header that pulls in
// <windows.h> (which otherwise smuggles in old <winsock.h> via mmsystem and
// triggers sockaddr/sockaddr_in redefinition in ws2def.h).
#include <httplib.h>
#include <nlohmann/json.hpp>

#include "HttpServerHooks.hpp"
#include "../ModLoader.hpp"
#include "../RMGlobal.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>

namespace rm_modloader {

	namespace {

		template<typename ... T>
		inline bool check_ruby_type(RubyValue value, T ... expected_types) {
			return ((rb_type(value) == expected_types) || ...);
		}

		// Synchronous TaskQueue that runs each task on the calling thread.
		// httplib::Server's default new_task_queue spins up a std::thread pool of
		// 8 workers, which internally use std::mutex / std::condition_variable.
		// Those crash in our process (same root cause as the earlier std::mutex
		// fix). Translator++ throughput is tiny — sync dispatch in the accept
		// loop handles it fine.
		class SyncTaskQueue : public httplib::TaskQueue {
		public:
			bool enqueue(std::function<void()> fn) override {
				fn();
				return true;
			}
			void shutdown() override {}
		};

		// Win32 primitives instead of std::mutex / std::condition_variable.
		// Reason: std::mutex from MSVC stdlib was crashing on first lock() inside
		// the RGSS3 process — likely a CRT init mismatch when the DLL is injected
		// before the game's normal startup. SRWLOCK + CONDITION_VARIABLE live in
		// NTDLL/KernelBase, no CRT dependency, work unconditionally.

		struct SrwGuard {
			explicit SrwGuard(SRWLOCK& l) : lock_(l) { AcquireSRWLockExclusive(&lock_); }
			~SrwGuard() { ReleaseSRWLockExclusive(&lock_); }
			SrwGuard(const SrwGuard&) = delete;
			SrwGuard& operator=(const SrwGuard&) = delete;
			SRWLOCK& lock_;
		};

		// Per-request slot the connection thread sleeps on until Ruby calls respond().
		struct ResponseSlot {
			SRWLOCK lock = SRWLOCK_INIT;
			CONDITION_VARIABLE cv = CONDITION_VARIABLE_INIT;
			int status = 504;
			std::string content_type = "text/plain";
			std::string body = "request timed out";
			bool ready = false;
		};

		// Singleton holding the httplib server, the pending-request map, and the
		// ready queue that Ruby drains via ModLoader.http_poll.
		class HttpServer {
		public:
			static HttpServer& instance() {
				static HttpServer i;
				return i;
			}

			bool listen(int port) {
				SrwGuard lock(mu_);
				if (running_) {
					return port_ == port; // idempotent on same port
				}

				port_ = port;
				server_ = std::make_unique<httplib::Server>();
				// Replace the default ThreadPool with our sync queue BEFORE any
				// handler can fire. httplib's std::thread/std::mutex-based pool
				// crashes inside the RGSS3 process; sync dispatch is plenty for
				// translator++ throughput.
				server_->new_task_queue = [] { return new SyncTaskQueue(); };

				// CORS: permissive defaults + explicit preflight handler.
				server_->set_default_headers({
					{"Access-Control-Allow-Origin", "*"},
				});
				server_->Options(R"(.*)", [](const httplib::Request&, httplib::Response& res) {
					res.set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
					res.set_header("Access-Control-Allow-Headers", "*");
					res.set_header("Access-Control-Max-Age", "600");
					res.status = 204;
				});

				// Catch-all handlers — every real request goes through the same path.
				auto catchall = [this](const httplib::Request& req, httplib::Response& res) {
					handle(req, res);
				};
				server_->Get   (R"(.*)", catchall);
				server_->Post  (R"(.*)", catchall);
				server_->Put   (R"(.*)", catchall);
				server_->Delete(R"(.*)", catchall);

				// httplib::Server::listen blocks; run on a dedicated thread.
				server_thread_ = std::thread([this] {
					try {
						server_->listen("127.0.0.1", port_);
					}
					catch (const std::exception& e) {
						mod_loader->log_error("http server thread crashed: {}\n", e.what());
					}
					catch (...) {
						mod_loader->log_error("http server thread crashed with unknown exception\n");
					}
				});

				running_ = true;
				mod_loader->log_info("http server listening on 127.0.0.1:{}\n", port_);
				return true;
			}

			void stop() {
				{
					SrwGuard lock(mu_);
					if (!running_) return;
					if (server_) server_->stop();

					// Wake any in-flight requests with 503 so their threads exit cleanly.
					for (auto& [id, slot] : pending_) {
						{
							SrwGuard sl(slot->lock);
							slot->status = 503;
							slot->content_type = "text/plain";
							slot->body = "server shutting down";
							slot->ready = true;
						}
						WakeAllConditionVariable(&slot->cv);
					}
					pending_.clear();
					ready_queue_.clear();
				}

				if (server_thread_.joinable()) {
					server_thread_.join();
				}

				SrwGuard lock(mu_);
				server_.reset();
				running_ = false;
			}

			// Called from Ruby main thread. Empty string == queue empty.
			std::string poll() {
				SrwGuard lock(mu_);
				if (ready_queue_.empty()) return {};
				std::string json = std::move(ready_queue_.front());
				ready_queue_.pop_front();
				return json;
			}

			// Called from Ruby main thread.
			bool respond(std::string_view id, int status, std::string_view content_type, std::string_view body) {
				std::shared_ptr<ResponseSlot> slot;
				{
					SrwGuard lock(mu_);
					auto it = pending_.find(std::string(id));
					if (it == pending_.end()) return false;
					slot = it->second;
					pending_.erase(it);
				}
				{
					SrwGuard sl(slot->lock);
					slot->status = status;
					slot->content_type = std::string(content_type);
					slot->body = std::string(body);
					slot->ready = true;
				}
				WakeAllConditionVariable(&slot->cv);
				return true;
			}

			size_t inflight_count() {
				SrwGuard lock(mu_);
				return pending_.size();
			}

		private:
			void handle(const httplib::Request& req, httplib::Response& res) {
				auto slot = std::make_shared<ResponseSlot>();
				std::string id = generate_id();

				// Build the JSON envelope Ruby will see via http_poll.
				std::map<std::string, std::string> headers;
				for (const auto& [k, v] : req.headers) {
					std::string key = k;
					std::transform(key.begin(), key.end(), key.begin(),
						[](unsigned char c) { return static_cast<char>(std::tolower(c)); });
					// RFC 7230: join duplicate header values with ", "
					auto it = headers.find(key);
					if (it == headers.end()) {
						headers.emplace(std::move(key), v);
					} else {
						it->second += ", ";
						it->second += v;
					}
				}

				nlohmann::json req_json = {
					{"id",      id},
					{"method",  req.method},
					{"path",    req.path},
					// TODO: httplib parses query into req.params (multimap); reassemble
					// raw query string here if/when Ruby callers need it. Empty for now.
					{"query",   std::string{}},
					{"headers", headers},
					{"body",    req.body},
				};

				{
					SrwGuard lock(mu_);
					pending_.emplace(id, slot);
					ready_queue_.push_back(req_json.dump());
				}

				// Block this connection thread until Ruby responds (or timeout / stop).
				{
					SrwGuard sl(slot->lock);
					const ULONGLONG deadline = GetTickCount64() + 30000;
					while (!slot->ready) {
						ULONGLONG now = GetTickCount64();
						if (now >= deadline) break;
						DWORD wait_ms = static_cast<DWORD>(deadline - now);
						SleepConditionVariableSRW(&slot->cv, &slot->lock, wait_ms, 0);
					}
				}

				if (!slot->ready) {
					// Timed out — clean up the pending entry if it's still there.
					SrwGuard lock(mu_);
					pending_.erase(id);
				}

				res.status = slot->status;
				res.set_content(slot->body, slot->content_type);
			}

			static std::string generate_id() {
				static std::atomic<uint64_t> counter{0};
				auto n = counter.fetch_add(1, std::memory_order_relaxed);
				auto t = std::chrono::steady_clock::now().time_since_epoch().count();
				return std::to_string(t) + "-" + std::to_string(n);
			}

			SRWLOCK mu_ = SRWLOCK_INIT;
			std::unique_ptr<httplib::Server> server_;
			std::thread server_thread_;
			std::unordered_map<std::string, std::shared_ptr<ResponseSlot>> pending_;
			std::deque<std::string> ready_queue_;
			int port_ = 0;
			bool running_ = false;
		};

		// Ruby method shims. All conversions go through helpers already in RMGlobal.
		struct HttpServerModule {

			static RubyValue __cdecl listen(RubyValue /*module*/, RubyValue port_value) {
				if (!check_ruby_type(port_value, RUBY_T_FIXNUM)) {
					rb_raise(*ruby_error_arg_error, "http_listen: expected port as fixnum");
					return ruby_nil;
				}
				const int port = static_cast<int>(rb_num2ull(port_value));
				return HttpServer::instance().listen(port) ? ruby_true : ruby_false;
			}

			static RubyValue __cdecl stop(RubyValue /*module*/) {
				HttpServer::instance().stop();
				return ruby_nil;
			}

			static RubyValue __cdecl poll(RubyValue /*module*/) {
				std::string json = HttpServer::instance().poll();
				if (json.empty()) return ruby_nil;
				return rb_str_new(json.data(), static_cast<long>(json.size()));
			}

			static RubyValue __cdecl respond(RubyValue /*module*/, RubyValue id_value,
				RubyValue status_value, RubyValue content_type_value, RubyValue body_value) {
				if (!check_ruby_type(id_value, RUBY_T_STRING)) {
					rb_raise(*ruby_error_arg_error, "http_respond: expected id as string");
					return ruby_nil;
				}
				if (!check_ruby_type(status_value, RUBY_T_FIXNUM)) {
					rb_raise(*ruby_error_arg_error, "http_respond: expected status as fixnum");
					return ruby_nil;
				}
				if (!check_ruby_type(content_type_value, RUBY_T_STRING)) {
					rb_raise(*ruby_error_arg_error, "http_respond: expected content_type as string");
					return ruby_nil;
				}
				if (!check_ruby_type(body_value, RUBY_T_STRING)) {
					rb_raise(*ruby_error_arg_error, "http_respond: expected body as string");
					return ruby_nil;
				}

				// rb_get_string_data → null-terminated; OK for id/content-type (ascii).
				std::string_view id = rb_get_string_data(&id_value);
				const int status = static_cast<int>(rb_num2ull(status_value));
				std::string_view content_type = rb_get_string_data(&content_type_value);
				// rb_str_value is binary-safe for heap-allocated strings (always the
				// case for non-trivial bodies like PNG dumps). Embedded strings cap
				// at ~11 bytes and our responses are larger, so no NUL truncation.
				std::string_view body = rb_str_value(body_value);

				return HttpServer::instance().respond(id, status, content_type, body)
					? ruby_true : ruby_false;
			}

			static RubyValue __cdecl inflight_count(RubyValue /*module*/) {
				return rb_make_number(static_cast<long>(HttpServer::instance().inflight_count()));
			}
		};

	} // anonymous namespace

	void apply_http_server_hooks() {
		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("http_listen",         HttpServerModule::listen);
			mod_loader->register_ruby_method("http_stop",           HttpServerModule::stop);
			mod_loader->register_ruby_method("http_poll",           HttpServerModule::poll);
			mod_loader->register_ruby_method("http_respond",        HttpServerModule::respond);
			mod_loader->register_ruby_method("http_inflight_count", HttpServerModule::inflight_count);
		});
	}
}
