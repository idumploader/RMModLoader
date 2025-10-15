#include "ModLoader.hpp"
#include "Hook.hpp"
#include "RMGlobal.hpp"
#include "HRFixHooks.hpp"
#include "FastRenderHooks.hpp"
#include "ControlsChangeHooks.hpp"

#include <fstream>
#include <locale>
#include <array>

std::string_view named_pipe_name = R"(\\.\pipe\WindowHookDebugLog)";

decltype(&IsDebuggerPresent) orig_IsDebuggerPresent;

BOOL WINAPI is_debugger_present_hook() {
	return false;
}

namespace rm_modloader::detail {

	int ModLoaderBooter::init() {
		MH_Initialize();
		init_functionset();
		mod_loader = std::make_shared<ModLoaderCore>(std::filesystem::current_path());
		mod_loader->setup_modloader_hooks();
		return 0;
	}

	int ModLoaderBooter::deinit() {
		mod_loader->clear_modloader_hooks();
		mod_loader = nullptr;
		MH_Uninitialize();
		return 0;
	}

}

namespace rm_modloader {
	struct ModLoaderRubyModule {
		static RubyValue __cdecl hrfix_enabled(RubyValue module) {
			return mod_loader->get_config().is_hrfix_enabled() ? ruby_true : ruby_false;
		}

		static RubyValue __cdecl fast_render_enabled(RubyValue module) {
			return mod_loader->get_config().is_fast_render_enabled() ? ruby_true : ruby_false;
		}

		static RubyValue __cdecl controls_change_enabled(RubyValue module) {
			return mod_loader->get_config().is_controls_change_enabled() ? ruby_true : ruby_false;
		}
	};

	struct ModLoaderCoreHooks {
		static int(__cdecl* orig_load_data)(int self, int a2);
		static int(__cdecl* orig_startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* compressed);

		static int __cdecl load_data_hook(int self, int a2) {
			const char* name = rb_get_string_data(reinterpret_cast<RubyValue>(&a2));
			mod_loader->log_info("load_data: {}\n", name);

			return orig_load_data(self, a2);
		}

		static int __cdecl startup_scripts_hook(const wchar_t* scripts_file, StartupScriptsString* compressed) {
			auto name = std::wstring_view(scripts_file);
			mod_loader->log_info("startup_scripts: loading from {}\n", std::string(name.begin(), name.end()));

			mod_loader->setup_mod_loader_ruby_module();
			mod_loader->on_preinit();

			int ret = orig_startup_scripts(scripts_file, compressed);

			mod_loader->on_postinit();
			mod_loader->log_info("startup_scripts: Executed post-init scripts. Starting game\n");

			mod_loader->execute_script("rgss_main { SceneManager.run }");

			return ret;
		}
	};

	int(__cdecl* ModLoaderCoreHooks::orig_load_data)(int self, int a2) = nullptr;
	int(__cdecl* ModLoaderCoreHooks::orig_startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* compressed) = nullptr;

	ModLoaderCore::ModLoaderCore(std::filesystem::path loader_root_path) :
		modloader_root_(std::move(loader_root_path)),
		last_patch_id_(0),
		last_handler_id_(0),
		debug_pipe_handle_(CreateFileA(named_pipe_name.data(), FILE_WRITE_ACCESS, 0, nullptr, OPEN_EXISTING, 0, nullptr))
	{
		try {
			config_ = ModLoaderConfig(modloader_root_ / modloader_data_dir / "mod_loader.json");
		}
		catch (const std::exception& e) {
			log_info("Failed to load config: {}\n", e.what());
			log_info("Using default values: \"width\"=1920, \"height\"=1000, \"hrfix_enable\"=true, \"fast_render_enabled\"=false,\"controls_change\"=true\n");
		}
		setup_directories();
	}

	ModLoaderCore::~ModLoaderCore() {
		CloseHandle(debug_pipe_handle_);
	}

	const std::filesystem::path& ModLoaderCore::get_game_dir() const {
		return modloader_root_;
	}

	std::filesystem::path ModLoaderCore::get_data_dir() const {
		return modloader_root_ / modloader_data_dir;
	}

	void* ModLoaderCore::get_rgss_base() const {
		return rgss_module;
	}
	void* ModLoaderCore::at_base_offset(intptr_t offset) const {
		return at_offset<void*>(get_rgss_base(), offset);
	}

	void ModLoaderCore::patch_memory(void* target, const void* data, size_t size) {
		memcpy(target, data, size);
	}

	const ModLoaderConfig& ModLoaderCore::get_config() const {
		return config_;
	}

	void ModLoaderCore::register_ruby_method(std::string_view name, void* function, int argument_count) {
		rb_register_module_method(ruby_module_, name.data(), function, argument_count);
	}

	ModLoaderPatchID ModLoaderCore::hook_function_internal(void* target, void* hook_func, void** orig_func) {
		MH_CreateHook(target, hook_func, orig_func);
		MH_EnableHook(target);
		return last_patch_id_++;
	}

	ModLoaderPatchID ModLoaderCore::hook_api_function_internal(std::wstring_view lib_name, std::string_view function_name, void* hook_func, void** orig_func) {
		void* target;
		MH_CreateHookApiEx(lib_name.data(), function_name.data(), hook_func, orig_func, &target);
		MH_EnableHook(target);
		return last_patch_id_++;
	}

	void ModLoaderCore::on_preinit() {
		for (auto& [id, handler] : preinit_handlers_) {
			handler();
		}
	}

	void ModLoaderCore::on_postinit() {
		for (auto& [id, handler] : postinit_handlers_) {
			handler();
		}

		execute_all_user_scripts();

		patched_decompress_script_ = nullptr;
	}

	void ModLoaderCore::execute_all_user_scripts() const {
		auto user_scripts_dir = modloader_root_ / modloader_data_dir / scripts_dir;
		for (auto& entry : std::filesystem::directory_iterator(user_scripts_dir)) {
			if (entry.is_directory()) continue;
			if (entry.path().extension() != ".rb") continue;

			std::ifstream script_is(entry.path());
			std::string script_content((std::istreambuf_iterator<char>(script_is)), std::istreambuf_iterator<char>());

			int error;
			execute_script(script_content, error);
			if (!error) {
				log_info("Executed script: {}\n", entry.path().string());
			}
			else {
				std::array<WCHAR, 512> error_buffer = {};
				int error_error = 0; // xD
				get_rb_error_string(error_buffer.data(), error_buffer.size(), &error_error);

				std::wstring_view error_wstr = error_buffer.data();
				log_info(
					"Failed executing script: {}\n"
					"Error: {}\n",
					entry.path().string(),
					std::string(error_wstr.begin(), error_wstr.end())
				);
			}
		}
	}

	void ModLoaderCore::setup_directories() {
		log_info("ModLoader version: {}. Current working dir: {}\n", version, std::filesystem::current_path().string());
		std::filesystem::create_directories(modloader_root_ / modloader_data_dir);
		std::filesystem::create_directories(modloader_root_ / modloader_data_dir / scripts_dir);
	}

	void ModLoaderCore::setup_modloader_hooks() {
		hook_api_function(L"kernel32.dll", "IsDebuggerPresent", is_debugger_present_hook, &orig_IsDebuggerPresent);

		if (!patched_decompress_script_) {
			// Copied script from RPG Maker. It loads and decompresses all scripts.
			// Changed, that it doesn't include "Main" scripts, who calls `rgss_main` and actually runs game. ModLoader will call `rgss_main` on it's own
			constexpr char load_script[] = "$RGSS_SCRIPTS = load_data(@scripts_fname);$RGSS_SCRIPTS.delete_if{ |s| s[1] == \"Main\" };$RGSS_SCRIPTS.each { |s| s[3,0] = Zlib::Inflate.inflate(s[2]) };$RGSS_SCRIPTS.size";

			patched_decompress_script_ = std::make_unique<char[]>(sizeof(load_script));
			strcpy_s(patched_decompress_script_.get(), sizeof(load_script), load_script);
			patch_memory_as<int>(0xEBA0, reinterpret_cast<intptr_t>(patched_decompress_script_.get()));
		}

		hook_function(load_data, &ModLoaderCoreHooks::load_data_hook, &ModLoaderCoreHooks::orig_load_data);
		hook_function(startup_scripts, &ModLoaderCoreHooks::startup_scripts_hook, &ModLoaderCoreHooks::orig_startup_scripts);

		if (config_.is_hrfix_enabled()) {
			apply_hrfix();
		}
		if (config_.is_fast_render_enabled()) {
			apply_fast_render();
		}
		if (config_.is_controls_change_enabled()) {
			apply_controls_change();
		}

		log_info("Applied all base hooks\n");
	}

	void ModLoaderCore::clear_modloader_hooks() {
		// TODO:
	}

	void ModLoaderCore::setup_mod_loader_ruby_module() {
		//add_preinit_handler([this] {
			ruby_module_ = rb_get_module("ModLoader");
			register_ruby_method("hrfix_enabled", ModLoaderRubyModule::hrfix_enabled);
			register_ruby_method("fast_render_enabled", ModLoaderRubyModule::fast_render_enabled);
			register_ruby_method("controls_change_enabled", ModLoaderRubyModule::controls_change_enabled);
		//});
	}

	GameFrame* ModLoaderCore::get_game() const {
		return *rgss_game;
	}

	int ModLoaderCore::execute_script(std::string_view script) const {
		return eval_rb_cstr_noerr(script.data());
	}

	int ModLoaderCore::execute_script(std::string_view script, int& error) const {
		BYTE unk_byte;
		return eval_rb_cstr(script.data(), &unk_byte, std::addressof(error));
	}

	ModLoaderHandlerID ModLoaderCore::add_preinit_handler(PreinitHandler handler) {
		ModLoaderHandlerID handler_id = last_handler_id_++;
		preinit_handlers_[handler_id] = std::move(handler);
		return handler_id;
	}

	void ModLoaderCore::remove_preinit_handler(ModLoaderHandlerID handler_id) {
		postinit_handlers_.erase(handler_id);
	}

	ModLoaderHandlerID ModLoaderCore::add_postinit_handler(PostinitHandler handler) {
		ModLoaderHandlerID handler_id = last_handler_id_++;
		postinit_handlers_[handler_id] = std::move(handler);
		return handler_id;
	}

	void ModLoaderCore::remove_postinit_handler(ModLoaderHandlerID handler_id) {
		postinit_handlers_.erase(handler_id);
	}

	constexpr std::string_view ModLoaderCore::version = "2.2";
	std::shared_ptr<ModLoaderCore> mod_loader;
}