#pragma once
#include "RMClasses.hpp"
#include "ModLoaderConfig.hpp"

#include <filesystem>
#include <unordered_map>
#include <functional>
#include <span>

namespace rm_modloader {
	namespace detail {
		/**
		 * This class startups all required methods and offsets for the mod loader
		 */
		class ModLoaderBooter {
		public:

			static int init();
			static int deinit();

			static void patch_game();
			static void run_game();

		private:

		};
	}

	using ModLoaderHandlerID = int64_t;
	using ModLoaderPatchID = int64_t;

	class ModLoaderCore {
		friend class detail::ModLoaderBooter;
		friend struct ModLoaderCoreHooks;

	public:
		static std::string_view version;

		using PreinitHandler = std::function<void()>;
		using PostinitHandler = std::function<void()>;

		static constexpr std::string_view modloader_data_dir = "mod_loader";
		static constexpr std::string_view scripts_dir = "scripts";

		ModLoaderCore(std::filesystem::path loader_root_path);
		~ModLoaderCore();

		void* get_rgss_base() const;
		void* at_base_offset(intptr_t offset) const;

		template<typename T>
		T at_base_offset_as(intptr_t offset) const {
			return std::bit_cast<T>(at_base_offset(offset));
		}

		GameFrame* get_game();

		int execute_script(std::string_view script) const;
		int execute_script(std::string_view script, int& error) const;

		ModLoaderHandlerID add_preinit_handler(PreinitHandler handler);
		void remove_preinit_handler(ModLoaderHandlerID handler_id);

		ModLoaderHandlerID add_postinit_handler(PostinitHandler handler);
		void remove_postinit_handler(ModLoaderHandlerID handler_id);

		template<typename T>
		ModLoaderPatchID hook_function(void* target, T hook_func, T* orig_func) {
			return hook_function_internal(target, hook_func, reinterpret_cast<void**>(orig_func));
		}

		template<typename T>
		ModLoaderPatchID hook_function(intptr_t offset, T hook_func, T* orig_func) {
			return hook_function(at_base_offset(offset), hook_func, orig_func);
		}

		template<typename T, typename THook, typename TMethod>
		ModLoaderPatchID hook_method(TMethod(T::* target), TMethod(THook::* hook_method), TMethod(T::** orig_method)) {
			return hook_function(std::bit_cast<void*>(target), std::bit_cast<void*>(hook_method), reinterpret_cast<void**>(orig_method));
		}

		template<typename T, typename THook, typename TMethod>
		ModLoaderPatchID hook_method(intptr_t offset, TMethod(THook::* hook_method), TMethod(T::** orig_method)) {
			return hook_function(offset, std::bit_cast<void*>(hook_method), reinterpret_cast<void**>(orig_method));
		}

		template<typename T>
		ModLoaderPatchID hook_api_function(std::wstring_view lib_name, std::string_view function_name, T hook_func, T* orig_func) {
			return hook_api_function_internal(lib_name, function_name, hook_func, reinterpret_cast<void**>(orig_func));
		}

		template<std::integral T>
		void patch_memory(intptr_t offset, T data) {
			patch_memory(at_base_offset(offset), &data, sizeof(data));
		}

		template<std::convertible_to<std::span<const char>> T>
		void patch_memory(intptr_t offset, T data) {
			patch_memory(at_base_offset(offset), data.data(), data.size());
		}

		template<typename TPatchData, std::integral T>
		void patch_memory_as(intptr_t offset, T data) {
			static_assert(sizeof(TPatchData) <= sizeof(T), "Cannot set patch for data type sizeof less than pointer set patch");
			patch_memory(at_base_offset(offset), &data, sizeof(TPatchData));
		}

		void patch_memory(void* target, const void* data, size_t size);

		template<typename ... Args>
		void log_info(const std::format_string<Args...> fmt, Args&& ... args) const {
			std::string msg = "[ModLoader INFO] " + std::format(std::move(fmt), std::forward<Args>(args) ...);
			DWORD written;
			WriteFile(debug_pipe_handle_, msg.c_str(), msg.size(), &written, nullptr);
		}
		
		const ModLoaderConfig& get_config() const;
		
	private:

		ModLoaderPatchID hook_function_internal(void* target, void* hook_func, void** orig_func);
		ModLoaderPatchID hook_api_function_internal(std::wstring_view lib_name, std::string_view function_name, void* hook_func, void** orig_func);

		/**
		 * This method is internally used by ModLoaderBooter
		 */
		void on_preinit();

		/**
		 * This method is internally used by ModLoaderBooter
		 */
		void on_postinit();

		void execute_all_user_scripts() const;

		void setup_directories();
		void setup_modloader_hooks();
		void clear_modloader_hooks();

		std::filesystem::path modloader_root_;
		
		ModLoaderPatchID last_patch_id_;
		ModLoaderHandlerID last_handler_id_;
		std::unordered_map<ModLoaderHandlerID, PreinitHandler> preinit_handlers_;
		std::unordered_map<ModLoaderHandlerID, PostinitHandler> postinit_handlers_;

		HANDLE debug_pipe_handle_;

		bool enable_hrfix_ = true;

		std::unique_ptr<char[]> patched_decompress_script_;

		ModLoaderConfig config_;
	};

	extern std::shared_ptr<ModLoaderCore> mod_loader;
};