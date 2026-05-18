#pragma once
#include "RMClasses.hpp"
#include "RMGlobal.hpp"
#include "ModLoaderConfig.hpp"

#include <filesystem>
#include <unordered_map>
#include <functional>
#include <span>
#include <iostream>

namespace rm_modloader {
	namespace detail {
		/**
		 * This class startups all required methods and offsets for the mod loader
		 */
		class ModLoaderBooter {
		public:

			/**
			 * Intializes hook environment and mod loader. Sets @ref mod_loader
			 */
			static int init();

			/**
			 * Cleanup mod loader and hook environment
			 */
			static int deinit();

			/**
			 * Initialize all mod loader base hooks
			 */
			static void patch_game();

			/**
			 * Run game with help of the mod loader
			 */
			static void run_game();
		};
	}

	using ModLoaderHandlerID = int64_t;
	using ModLoaderPatchID = int64_t;

	class ModLoaderCore {
		friend class detail::ModLoaderBooter;
		friend struct ModLoaderCoreHooks;
		friend struct ModLoaderRubyModule;

	public:
		static const std::string_view version;

		using PreinitHandler = std::function<void()>;
		using PostinitHandler = std::function<void()>;

		static constexpr std::string_view modloader_data_dir = "mod_loader";
		static constexpr std::string_view scripts_dir = "scripts";
		static constexpr std::string_view preinit_scripts_dir = "scripts_preinit";

		ModLoaderCore(std::filesystem::path loader_root_path);
		ModLoaderCore(const ModLoaderCore& other) = delete;
		ModLoaderCore(ModLoaderCore&& other) = default;
		~ModLoaderCore();

		/**
		 * Get the ModLoader game path, where .exe contains
		 * @return Game root path
		 */
		const std::filesystem::path& get_game_dir() const;

		/**
		 * Get the ModLoader content path, where contains scripts and other mod required information
		 * @return ModLoader mod's content path
		 */
		std::filesystem::path get_data_dir() const;

		/**
		 * Get the RGSS module base address
		 * @return base address
		 */
		void* get_rgss_base() const;

		/**
		 * Get the address with offset from RGSS base address
		 * @return offsetted address
		 */
		void* at_base_offset(ptrdiff_t offset) const;

		/**
		 * Get the address with offset from RGSS base address as the given type
		 * @tparam Type pointed by
		 * @param offset Offset from base address
		 * @return offsetted address
		 */
		template<typename T>
		T at_base_offset_as(ptrdiff_t offset) const {
			return std::bit_cast<T>(at_base_offset(offset));
		}

		/**
		 * Get GameFrame pointer. It contains general information about game, like screen, input, etc. @ref GameFrame
		 * @return GameFrame pointer
		 */
		GameFrame* get_game() const;

		/**
		 * Execute given Ruby script syncronously
		 * @param script Ruby scripts content
		 * @return Last evaluated ruby object
		 */
		int execute_script(std::string_view script) const;

		/**
		 * Execute given Ruby script syncronously
		 * @param script Ruby scripts content
		 * @param script_name Named of the script. Used when getting error string
		 * @param error Reference to output error code. Error if > 0
		 * @return Last evaluated ruby object
		 */
		int execute_script(std::string_view script, std::string_view script_name, int& error) const;

		/**
		 * Add pre-init handler. It's executed right before game scripts executed
		 * @param handler Function to be executed
		 * @return The handler ID, used to remove handler from queue. @ref remove_preinit_handler
		 */
		ModLoaderHandlerID add_preinit_handler(PreinitHandler handler);

		/**
		 * Remove pre-init handler. @ref add_preinit_handler
		 * @param handler_id The handler ID
		 */
		void remove_preinit_handler(ModLoaderHandlerID handler_id);

		/**
		 * Add post-init handler. It's executed after all game scripts are executed, but before "rgss_main"
		 * @param handler Function to be executed
		 * @return The handler ID, used to remove handler from queue. @ref remove_postinit_handler
		 */
		ModLoaderHandlerID add_postinit_handler(PostinitHandler handler);

		/**
		 * Remove post-init handler. @ref add_postinit_handler
		 * @param handler_id The handler ID
		 */
		void remove_postinit_handler(ModLoaderHandlerID handler_id);

		/**
		 * Hook function at given address.
		 * @tparam T Hook function pointer type
		 * @param target Address of the function to be hooked
		 * @param hook_func Hook function
		 * @param orig_func Pointer to variable, reciving original (trampoline) function pointer
		 * @return Patch ID. Currently unused
		 */
		template<typename T>
		ModLoaderPatchID hook_function(void* target, T hook_func, T* orig_func) {
			return hook_function_internal(target, hook_func, reinterpret_cast<void**>(orig_func));
		}

		/**
		 * Hook function at given offset from RGSS. @ref at_base_offset
		 * @tparam T Hook function pointer type
		 * @param offset Offset from RGSS module base address
		 * @param hook_func Hook function
		 * @param orig_func Pointer to variable, reciving original (trampoline) function pointer
		 * @return Patch ID. Currently unused
		 */
		template<typename T>
		ModLoaderPatchID hook_function(ptrdiff_t offset, T hook_func, T* orig_func) {
			return hook_function(at_base_offset(offset), hook_func, orig_func);
		}

		/**
		 * Hook class method (__thiscall) at given address. @ref at_base_offset
		 * @tparam T Hook function pointer type
		 * @param target Pointer to the hooked method
		 * @param hook_func Hook function
		 * @param orig_func Pointer to variable, reciving original (trampoline) function pointer
		 * @return Patch ID. Currently unused
		 */
		template<typename T, std::derived_from<T> THook, typename TMethod>
		ModLoaderPatchID hook_method(TMethod(T::* target), TMethod(THook::* hook_method), TMethod(T::** orig_method)) {
			return hook_function(std::bit_cast<void*>(target), std::bit_cast<void*>(hook_method), reinterpret_cast<void**>(orig_method));
		}

		/**
		 * Hook class method (__thiscall) at given offset from RGSS base. @ref at_base_offset
		 * @tparam T Original class
		 * @tparam THook Hook class
		 * @tparam TMethod Hooked method type
		 * @param offset Offset from RGSS module base address
		 * @param hook_method Hook method
		 * @param orig_method Pointer to variable, reciving original (trampoline) method pointer
		 * @return Patch ID. Currently unused
		 */
		template<typename T, std::derived_from<T> THook, typename TMethod>
		ModLoaderPatchID hook_method(ptrdiff_t offset, TMethod(THook::* hook_method), TMethod(T::** orig_method)) {
			return hook_function(offset, std::bit_cast<void*>(hook_method), reinterpret_cast<void**>(orig_method));
		}

		/**
		 * Hook API function. Used hook external library function, e.g. "kernel32.dll", "gdi32.dll", etc.
		 * @tparam T Hooked function pointer type
		 * @param lib_name Runtime library file name
		 * @param function_name The library export symbol
		 * @param hook_func Hook function
		 * @param orig_func Pointer to variable, reciving original (trampoline) function pointer
		 * @return Patch ID. Currently unused
		 */
		template<typename T>
		ModLoaderPatchID hook_api_function(std::wstring_view lib_name, std::string_view function_name, T hook_func, T* orig_func) {
			return hook_api_function_internal(lib_name, function_name, hook_func, reinterpret_cast<void**>(orig_func));
		}

		/**
		 * Write data to memory at offset from RGSS base address
		 * @tparam T Write data type
		 * @param offset Offset from base address
		 * @param data Value to write to the offsetted address
		 */
		template<std::integral T>
		void patch_memory(ptrdiff_t offset, T data) {
			patch_memory(at_base_offset(offset), &data, sizeof(data));
		}

		/**
		 * Write data array to memory at offset from RGSS base address
		 * @tparam T Array data type
		 * @param offset Offset from base address
		 * @param data Values to write to the offsetted address
		 */
		template<std::convertible_to<std::span<const char>> T>
		void patch_memory(ptrdiff_t offset, T data) {
			patch_memory(at_base_offset(offset), data.data(), data.size_bytes());
		}

		/**
		 * Write data array to memory at offset from RGSS base address.
		 * Converts data type to TPatchData and then writes it
		 * @tparam TPatchData Type of the data to directly write. Cannot be less than T in size
		 * @tparam T Data type
		 * @param offset Offset from base address
		 * @param data Values to write to the offsetted address
		 */
		template<std::integral TPatchData, std::convertible_to<const TPatchData> T>
			requires (sizeof(TPatchData) <= sizeof(T))
		void patch_memory_as(ptrdiff_t offset, T data) {
			patch_memory(at_base_offset(offset), &data, sizeof(TPatchData));
		}

		/**
		 * Write raw data to given address. Use only if you have to. Otherwise use some of templated functions
		 * @param target Address to write to
		 * @param data Pointer to data
		 * @param size Size in bytes to write from data
		 */
		void patch_memory(void* target, const void* data, size_t size);

		/**
		 * Print info log to user
		 * @tparam TArgs Format arguments types
		 * @param fmt Format string. @ref std::format
		 * @param args ... Format arguments
		 */
		template<typename ... TArgs>
		void log_info(const std::format_string<TArgs...> fmt, TArgs&& ... args) const {
			std::string msg = "[ModLoader INFO] " + std::format(std::move(fmt), std::forward<TArgs>(args) ...);
			log(msg);
		}

		/**
		 * Print warning log to user
		 * @tparam TArgs Format arguments types
		 * @param fmt Format string. @ref std::format
		 * @param args ... Format arguments
		 */
		template<typename ... TArgs>
		void log_warning(const std::format_string<TArgs...> fmt, TArgs&& ... args) const {
			std::string msg = "\x1B[0;33m[ModLoader INFO] " + std::format(std::move(fmt), std::forward<TArgs>(args) ...) + "\x1B[0m";
			log(msg);
		}

		/**
		 * Print error log to user
		 * @tparam TArgs Format arguments types
		 * @param fmt Format string. @ref std::format
		 * @param args ... Format arguments
		 */
		template<typename ... TArgs>
		void log_error(const std::format_string<TArgs...> fmt, TArgs&& ... args) const {
			std::string msg = "\x1B[0;31m[ModLoader INFO] " + std::format(std::move(fmt), std::forward<TArgs>(args) ...) + "\x1B[0m";
			log(msg);
		}

		/**
		 * Print critical error log to user
		 * @tparam TArgs Format arguments types
		 * @param fmt Format string. @ref std::format
		 * @param args ... Format arguments
		 */
		template<typename ... TArgs>
		void log_critical(const std::format_string<TArgs...> fmt, TArgs&& ... args) const {
			std::string msg = "\x1B[41;37m[ModLoader INFO] " + std::format(std::move(fmt), std::forward<TArgs>(args) ...) + "\x1B[0m";
			log(msg);
		}

		/**
		 * Print raw log string
		 * @param msg log message
		 */
		void log(std::string_view msg) const;
		
		/**
		 * Get mod loader config. It contains all the settings for mod loader
		 * @return Reference to @see ModLoaderConfig
		 */
		const ModLoaderConfig& get_config() const;

		/**
		 * Register ruby "ModLoader" module method.
		 * It can be called from ruby script.
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 * @param argument_count Method arguments count
		 */
		void register_ruby_method(std::string_view name, void* function, int argument_count);

		/**
		 * Define ruby class/module method.
		 * It can be then called from ruby script.
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @param klass Ruby class/module
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 * @param argument_count Method arguments count
		 */
		//void define_ruby_method(RubyValue klass, std::string_view name, void* function, int argument_count);

		/**
		 * Define ruby class/module singleton method (static method).
		 * It can be then called from ruby script.
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @param klass Ruby class/module
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 * @param argument_count Method arguments count
		 */
		//void define_ruby_singleton_method(RubyValue klass, std::string_view name, void* function, int argument_count);

		/**
		 * Register ruby "ModLoader" module method
		 * It can be called from ruby script
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @tparam TRet return type of function
		 * @tparam TArgs ... method function arguments
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 */
		template<typename TRet, typename ... TArgs>
		void register_ruby_method(std::string_view name, TRet(__cdecl *function)(RubyValue, TArgs...)) {
			register_ruby_method(name, function, sizeof...(TArgs));
		}

		/**
		 * Define ruby class/module method.
		 * It can be then called from ruby script.
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @param klass Ruby class/module
		 * @tparam TRet return type of function
		 * @tparam TArgs ... method function arguments
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 */
		//template<typename TRet, typename ... TArgs>
		//void define_ruby_method(RubyValue klass, std::string_view name, TRet(__cdecl* function)(RubyValue, TArgs...)) {
		//	define_ruby_method(klass, name, function, sizeof...(TArgs));
		//}

		/**
		 * Define ruby class/module singleton method (static method).
		 * It can be then called from ruby script.
		 * @note Inside the method body, you should raise RubyModException instead of rb_raise.
		 *       Otherwise, local variables in method body may not be properly released, which can cause memory leak.
		 * @note You can only register after preinit stage. @see add_preinit_handler
		 * @param klass Ruby class/module
		 * @tparam TRet return type of function
		 * @tparam TArgs ... method function arguments
		 * @param name Name of the method
		 * @param function Method body function, it executed when called from ruby script
		 */
		//template<typename TRet, typename ... TArgs>
		//void define_ruby_singleton_method(RubyValue klass, std::string_view name, TRet(__cdecl* function)(RubyValue, TArgs...)) {
		//	define_ruby_singleton_method(klass, name, function, sizeof...(TArgs));
		//}

		
	private:

		ModLoaderPatchID hook_function_internal(void* target, void* hook_func, void** orig_func);
		ModLoaderPatchID hook_api_function_internal(std::wstring_view lib_name, std::string_view function_name, void* hook_func, void** orig_func);

		/**
		 * Internal ruby log method
		 * @tparam TArgs Format arguments types
		 * @param fmt Format string. @ref std::format
		 * @param args ... Format arguments
		 */
		template<typename ... TArgs>
		void log_ruby(const std::format_string<TArgs...> fmt, TArgs&& ... args) const {
			std::string msg = "\x1B[38;5;214m[Ruby] " + std::format(std::move(fmt), std::forward<TArgs>(args) ...) + "\x1B[0m";
			log(msg);
		}

		/**
		 * This method is internally used by ModLoaderBooter
		 */
		void on_preinit();

		/**
		 * This method is internally used by ModLoaderBooter
		 */
		void on_postinit();

		/**
		 * Execute all ruby scripts in given directory with .rb extension.
		 * The scripts are ordered by prefixed priority. "(\d+) - .*.rb"
		 * If some script failed to execute, the error will be logged.
		 * @param scripts_dir directory where to walk and execute ruby scripts.
		 */
		void execute_all_user_scripts_in(const std::filesystem::path& scripts_dir) const;

		/**
		 * Create all directories needed for ModLoader
		 */
		void setup_directories();

		/**
		 * Setup all hooks needed for ModLoader
		 */
		void setup_modloader_hooks();

		/**
		 * @todo
		 */
		void clear_modloader_hooks();

		/**
		 * Create ModLoader ruby module, which can be accessed from scripts.
		 * Can be used in preinit and postinit scripts.
		 * 
		 * ModLoader.hrfix_enabled - returns if the HRFix is enabled in config.
		 * ModLoader.fast_render_enabled - returns if the FastRender is enabled in config.
		 * ModLoader.controls_change_enabled - returns if the ControlsChange is enabled in config.
		 * ModLoader.version - returns current version of the ModLoader as string.
		 * ModLoader.data_directory - returns current root data directory of the ModLoader as string.
		 */
		void setup_mod_loader_ruby_module();

		std::filesystem::path modloader_root_;
		
		ModLoaderPatchID last_patch_id_;
		ModLoaderHandlerID last_handler_id_;
		std::unordered_map<ModLoaderHandlerID, PreinitHandler> preinit_handlers_;
		std::unordered_map<ModLoaderHandlerID, PostinitHandler> postinit_handlers_;

		ModLoaderConfig config_;
		RubyValue ruby_module_;
	};

	class RubyModException : public std::exception {
	public:
		RubyModException(RubyValue klass, const char* message);

		RubyValue klass() const;

	private:
		RubyValue klass_;
	};

	template<typename T>
	RubyValue wrap_ruby_exception_safe(T func) {
		try {
			return func();
		}
		catch (const RubyModException& e) {
			rb_raise(e.klass(), e.what());
			return ruby_nil; // to fix warning
		}
	}

	/**
	 * Global pointer to ModLoader. Used to hook, patch game, execute scripts and print information.
	 * @see ModLoaderCore
	 */
	extern std::shared_ptr<ModLoaderCore> mod_loader;
};