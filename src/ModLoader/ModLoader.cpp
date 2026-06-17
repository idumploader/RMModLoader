#include "ModLoader.hpp"
#include "Hook.hpp"
#include "RMGlobal.hpp"
#include "GLFWMisc.hpp"
#include "Hooks.hpp"
#include "Logger.hpp"

#include <fstream>
#include <locale>
#include <array>
#include <cwctype>

#undef max
#undef min

std::string_view named_pipe_name = R"(\\.\pipe\WindowHookDebugLog)";

decltype(&IsDebuggerPresent) orig_IsDebuggerPresent;

BOOL WINAPI is_debugger_present_hook() {
	return false;
}

namespace rm_modloader::detail {

	namespace {
		// Resolve the RGSS runtime DLL path the way the game does: an explicit
		// "rgss_library" override in mod_loader.json (rare — for protected or
		// non-standard games), otherwise the [Game] Library= key in Game.ini next
		// to Game.exe. Throws if neither is present, so we fail loudly instead of
		// LoadLibrary'ing a hard-coded guess.
		std::filesystem::path resolve_rgss_library_path(const ModLoaderConfig& config) {
			if (const nlohmann::json* forced = config.get("rgss_library");
				forced && forced->is_string()) {
				const std::string forced_path = forced->get<std::string>();
				if (!forced_path.empty()) {
					return std::filesystem::path(forced_path);
				}
			}

			const std::wstring ini_path = (std::filesystem::current_path() / "Game.ini").wstring();
			wchar_t library[MAX_PATH] = {};
			const DWORD len = GetPrivateProfileStringW(L"Game", L"Library", L"", library, MAX_PATH, ini_path.c_str());
			if (len > 0 && library[0] != L'\0') {
				return std::filesystem::path(std::wstring(library, len));
			}

			throw std::runtime_error(
				"Could not determine the RGSS library to load: no \"rgss_library\" key in "
				"mod_loader.json and no [Game] Library= entry in Game.ini");
		}
	}

	int ModLoaderBooter::init() {
		if (MH_Initialize() != MH_OK) {
			return -1;
		}
		if (Logger::init(named_pipe_name) != 0) {
			return -1;
		}
		try {
			// Create the core first so the config is loaded before we resolve and
			// load the RGSS DLL (the "rgss_library" override lives in the config).
			// The ctor touches no RGSS state, so this ordering is safe.
			mod_loader = std::make_shared<ModLoaderCore>(std::filesystem::current_path());
			init_functionset(resolve_rgss_library_path(mod_loader->get_config()));
			mod_loader->setup_modloader_hooks();
		} catch (const std::exception& ex) {
			Logger::critical(std::string("\x1B[0;31mFailed to initialize mod loader: ") + ex.what() + "\x1B[0m");
			// don't deinit logger, because log window will close
			//(void)Logger::deinit();
			MH_Uninitialize();
			return -1;
		}
		return 0;
	}

	int ModLoaderBooter::deinit() {
		mod_loader->clear_modloader_hooks();
		mod_loader = nullptr;
		// don't deinit logger, because log window will close
		//(void)Logger::deinit();
		MH_Uninitialize();
		return 0;
	}

}

namespace rm_modloader {
	static RubyValue rb_call_cfunc_copy(RubyValue recv, RubyValue* argv, int argc, void* func) {
		switch (argc) {
		case -2: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue);

			RubyValue args_array = rb_ary_new4(argc, argv);
			return reinterpret_cast<FuncType>(func)(recv, args_array);
		}

		case -1: {
			using FuncType = RubyValue(*)(int, RubyValue*, RubyValue);
			return reinterpret_cast<FuncType>(func)(argc, argv, recv);
		}

		case 0: {
			using FuncType = RubyValue(*)(RubyValue);
			return reinterpret_cast<FuncType>(func)(recv);
		}

		case 1: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0]);
		}

		case 2: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1]);
		}

		case 3: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2]);
		}

		case 4: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3]);
		}

		case 5: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4]);
		}

		case 6: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
		}

		case 7: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
		}

		case 8: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7]);
		}

		case 9: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8]);
		}

		case 10: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9]);
		}

		case 11: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue,
				RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9], argv[10]);
		}

		case 12: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue,
				RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9], argv[10], argv[11]);
		}

		case 13: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue,
				RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9], argv[10], argv[11], argv[12]);
		}

		case 14: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue,
				RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9], argv[10], argv[11],
				argv[12], argv[13]);
		}

		case 15: {
			using FuncType = RubyValue(*)(RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue,
				RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue, RubyValue);
			return reinterpret_cast<FuncType>(func)(recv, argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
				argv[6], argv[7], argv[8], argv[9], argv[10], argv[11],
				argv[12], argv[13], argv[14]);
		}

		default:
			rb_raise(*ruby_error_arg_error, "too many arguments(%d)", argc);
		}
	}

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

		static RubyValue __cdecl data_directory(RubyValue module) {
			return rb_str_new_cstr(ModLoaderCore::modloader_data_dir.data());
		}

		static RubyValue __cdecl version(RubyValue module) {
			return rb_str_new_cstr(ModLoaderCore::version.data());
		}

		static RubyValue __cdecl log_ruby(RubyValue module, RubyValue log_string) {
			std::string_view msg = rb_get_string_data(&log_string);
			if (msg != "\n") {
				mod_loader->log_ruby("{}", msg);
			} else {
				mod_loader->log(msg);
			}
			return ruby_true;
		}
		
		static RubyValue __cdecl config_get(RubyValue module, RubyValue key_value) {
			std::string_view key = rb_get_string_data(&key_value);
			if (key.empty()) {
				return ruby_nil;
			}
			if (!mod_loader->get_config().contains(key)) {
				rb_raise(*ruby_error_arg_error, "ModLoader config key not found");
				return ruby_nil;
			}

			const auto& value = mod_loader->get_config().at(key);
			if (value.is_string()) {
				return rb_str_new_cstr(static_cast<std::string_view>(value).data());
			}
			if (value.is_boolean()) {
				return static_cast<bool>(value) ? ruby_true : ruby_false;
			}
			if (value.is_number()) {
				return rb_make_number(value);
			}
			if (value.is_null()) {
				return ruby_nil;
			}
			rb_raise(*ruby_error_arg_error, "Cannot convert ModLoader config value");
			return ruby_nil;
		}

		static RubyValue __cdecl version_major(RubyValue module) {
			return rb_make_number(RM_MODLOADER_VERSION_MAJOR);
		}

		static RubyValue __cdecl version_minor(RubyValue module) {
			return rb_make_number(RM_MODLOADER_VERSION_MINOR);
		}
	};

	struct ModLoaderCoreHooks {
		static int(__cdecl* orig_load_data)(RubyValue self, RubyValue a2);
		static int(__cdecl* orig_startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* compressed);

		static int __cdecl load_data_hook(RubyValue self, RubyValue a2) {
			const char* name = rb_get_string_data(&a2);
			mod_loader->log_info("load_data: {}\n", name);

			return orig_load_data(self, a2);
		}

		static int __cdecl fake_rgss_main(int a1) {
			mod_loader->on_postinit();
			mod_loader->log_info("fake_rgss_main: Executed post-init scripts. Starting game\n");

			int error;
			mod_loader->execute_script("rgsssmain { SceneManager.run }", "ModLoaderMainRunner", error);
			if (error) {
				std::array<WCHAR, 512> error_buffer = {};
				int error_error = 0; // xD
				get_rb_error_string(error_buffer.data(), error_buffer.size(), &error_error);

				std::wstring_view error_wstr = error_buffer.data();
				MessageBoxW(mod_loader->get_game()->window_handle, error_wstr.data(), L"Error", MB_OK | MB_ICONERROR);
			}

			return 1;
		}

		static int __cdecl startup_scripts_hook(const wchar_t* scripts_file, StartupScriptsString* compressed) {
			auto name = std::wstring_view(scripts_file);
			auto compressed_view = std::wstring_view(compressed->buffer);
			mod_loader->log_info("startup_scripts: loading from {}. RGSS string: {}\n", std::string(name.begin(), name.end()), std::string(compressed_view.begin(), compressed_view.end()));

			mod_loader->setup_mod_loader_ruby_module();
			mod_loader->on_preinit();

			return orig_startup_scripts(scripts_file, compressed);
		}
	};

	int(__cdecl* ModLoaderCoreHooks::orig_load_data)(RubyValue self, RubyValue a2) = nullptr;
	int(__cdecl* ModLoaderCoreHooks::orig_startup_scripts)(const wchar_t* scripts_file, StartupScriptsString* compressed) = nullptr;

	ModLoaderCore::ModLoaderCore(std::filesystem::path loader_root_path) :
		modloader_root_(std::move(loader_root_path)),
		last_patch_id_(0),
		last_handler_id_(0)
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
	void* ModLoaderCore::at_base_offset(ptrdiff_t offset) const {
		return at_offset<void*>(get_rgss_base(), offset);
	}

	void ModLoaderCore::patch_memory(void* target, const void* data, size_t size) {
		memcpy(target, data, size);
	}

	void ModLoaderCore::log(std::string_view msg) const {
		Logger::log(LogLevel::Info, msg);
	}

	const ModLoaderConfig& ModLoaderCore::get_config() const {
		return config_;
	}

	void ModLoaderCore::register_ruby_method(std::string_view name, void* function, int argument_count) {
		rb_define_singleton_method(ruby_module_, name.data(), function, argument_count);
	}

	//void ModLoaderCore::define_ruby_method(RubyValue klass, std::string_view name, void* function, int argument_count) {

	//}

	//void ModLoaderCore::define_ruby_singleton_method(RubyValue klass, std::string_view name, void* function, int argument_count) {

	//}

	// Splice a new hook onto the tail of an existing chain. The old tail used to
	// call the real function (its orig == trampoline); now it calls the new detour,
	// and the new hook becomes the tail that calls the real function. Touches no
	// MinHook state -- only two pointer stores.
	ModLoaderPatchID ModLoaderCore::append_to_chain(HookChain& chain, void* hook_func, void** orig_func, void* target) {
		*chain.entries.back().orig_slot = hook_func;
		*orig_func = chain.trampoline;
		ModLoaderPatchID id = last_patch_id_++;
		chain.entries.push_back({ id, hook_func, orig_func });
		patch_targets_[id] = target;
		return id;
	}

	ModLoaderPatchID ModLoaderCore::hook_function_internal(void* target, void* hook_func, void** orig_func) {
		std::lock_guard<std::mutex> lock(hook_registry_mutex_);

		if (auto it = hook_chains_.find(target); it != hook_chains_.end()) {
			return append_to_chain(it->second, hook_func, orig_func, target);
		}

		HookChain& chain = hook_chains_[target];
		if (MH_CreateHook(target, hook_func, &chain.trampoline) != MH_OK) {
			hook_chains_.erase(target);
			log_error("hook_function: MH_CreateHook failed for {}\n", target);
			return invalid_patch_id;
		}
		*orig_func = chain.trampoline;
		ModLoaderPatchID id = last_patch_id_++;
		chain.entries.push_back({ id, hook_func, orig_func });
		patch_targets_[id] = target;
		MH_EnableHook(target);
		return id;
	}

	ModLoaderPatchID ModLoaderCore::hook_api_function_internal(std::wstring_view lib_name, std::string_view function_name, void* hook_func, void** orig_func) {
		std::lock_guard<std::mutex> lock(hook_registry_mutex_);

		// Resolve the export so a second hook on the same function chains instead of
		// failing inside MinHook with MH_ERROR_ALREADY_CREATED.
		void* target = nullptr;
		if (HMODULE module = GetModuleHandleW(std::wstring(lib_name).c_str())) {
			target = reinterpret_cast<void*>(GetProcAddress(module, std::string(function_name).c_str()));
		}
		if (target) {
			if (auto it = hook_chains_.find(target); it != hook_chains_.end()) {
				return append_to_chain(it->second, hook_func, orig_func, target);
			}
		}

		HookChain chain;
		void* mh_target = nullptr;
		if (MH_CreateHookApiEx(std::wstring(lib_name).c_str(), std::string(function_name).c_str(),
				hook_func, &chain.trampoline, &mh_target) != MH_OK) {
			log_error("hook_api_function: MH_CreateHookApiEx failed for {}\n", std::string(function_name));
			return invalid_patch_id;
		}
		*orig_func = chain.trampoline;
		ModLoaderPatchID id = last_patch_id_++;
		chain.entries.push_back({ id, hook_func, orig_func });
		hook_chains_[mh_target] = std::move(chain);
		patch_targets_[id] = mh_target;
		MH_EnableHook(mh_target);
		return id;
	}

	void ModLoaderCore::unhook(ModLoaderPatchID patch_id) {
		if (patch_id == invalid_patch_id) {
			return;
		}

		std::lock_guard<std::mutex> lock(hook_registry_mutex_);

		auto pit = patch_targets_.find(patch_id);
		if (pit == patch_targets_.end()) {
			log_warning("unhook: unknown patch id {}\n", patch_id);
			return;
		}
		void* target = pit->second;
		patch_targets_.erase(pit);

		auto cit = hook_chains_.find(target);
		if (cit == hook_chains_.end()) {
			return;
		}
		HookChain& chain = cit->second;
		std::vector<HookEntry>& entries = chain.entries;

		size_t index = entries.size();
		for (size_t k = 0; k < entries.size(); ++k) {
			if (entries[k].id == patch_id) { index = k; break; }
		}
		if (index == entries.size()) {
			return;
		}

		// Last hook on this target: tear the MinHook down completely.
		if (entries.size() == 1) {
			MH_DisableHook(target);
			MH_RemoveHook(target);
			hook_chains_.erase(cit);
			return;
		}

		// Head removal: the target's jmp points at this detour and MinHook owns it,
		// so re-create the hook on the next detour (the only case that touches
		// MinHook), then re-point the tail's orig at the freshly allocated trampoline.
		if (index == 0) {
			void* new_head = entries[1].detour;
			MH_DisableHook(target);
			MH_RemoveHook(target);
			if (MH_CreateHook(target, new_head, &chain.trampoline) != MH_OK) {
				log_error("unhook: MH_CreateHook (re-head) failed for {}\n", target);
				return;
			}
			*entries.back().orig_slot = chain.trampoline;
			MH_EnableHook(target);
			entries.erase(entries.begin());
			return;
		}

		// Middle or tail: just re-point the predecessor's orig past the removed node.
		void* next = (index + 1 < entries.size()) ? entries[index + 1].detour : chain.trampoline;
		*entries[index - 1].orig_slot = next;
		entries.erase(entries.begin() + index);
	}

	void ModLoaderCore::on_preinit() {
		init_glfw();

		rb_define_function("rgss_main", ModLoaderCoreHooks::fake_rgss_main, 0);

		for (auto& [id, handler] : preinit_handlers_) {
			handler();
		}

		execute_all_user_scripts_in(modloader_root_ / modloader_data_dir / preinit_scripts_dir);
	}

	void ModLoaderCore::on_postinit() {
		for (auto& [id, handler] : postinit_handlers_) {
			handler();
		}

		execute_all_user_scripts_in(modloader_root_ / modloader_data_dir / scripts_dir);
	}

	void ModLoaderCore::execute_all_user_scripts_in(const std::filesystem::path& scripts_dir) const {
		std::vector<std::filesystem::directory_entry> scripts_entries(std::filesystem::directory_iterator(scripts_dir), std::filesystem::directory_iterator{});
		std::erase_if(scripts_entries, [](const auto& entry) -> bool {
			return entry.is_directory() || entry.path().extension() != ".rb";
		});

		auto entry_to_enum_index = [this](const auto& entry) {
			std::string filename = entry.path().filename().string();
			size_t enum_pos = filename.find(" - ");
			if (enum_pos == std::string::npos) {
				log_warning("file {} has invalid enumeration filename syntax (should be \"dddd - *.rb\"). Placing at the end.\n", filename);
				return std::numeric_limits<int64_t>::max();
			}
			std::istringstream filename_stream(filename.substr(0, enum_pos));

			int64_t index;
			filename_stream >> index;
			if (filename_stream.fail()) {
				log_warning("file {} has invalid enumeration filename syntax (should be \"dddd - *.rb\"). Placing at the end.\n", filename);
				return std::numeric_limits<int64_t>::max();
			}
			return index;
		};
		std::sort(scripts_entries.begin(), scripts_entries.end(), [&entry_to_enum_index](const auto& left, const auto& right) {
			return entry_to_enum_index(left) < entry_to_enum_index(right);
		});

		for (auto& entry : scripts_entries) {
			std::ifstream script_is(entry.path());
			std::string script_content((std::istreambuf_iterator<char>(script_is)), std::istreambuf_iterator<char>());

			int error;
			//execute_script(script_content, "ModLoaderEvaluator", error);
			execute_script(script_content, entry.path().filename().string(), error);
			if (!error) {
				log_info("Executed script: {}\n", entry.path().string());
			}
			else {
				std::array<WCHAR, 512> error_buffer = {};
				int error_error = 0; // xD
				get_rb_error_string(error_buffer.data(), error_buffer.max_size(), &error_error);

				std::wstring_view error_wstr = error_buffer.data();
				auto parsed_error = error_wstr | std::views::transform([](wchar_t c) {
					return std::iswprint(c) || c == L'\n' ? c : L'?';
				});
				log_error(
					"Failed executing script: {}\n"
					"Error: {}\n",
					entry.path().string(),
					std::string(parsed_error.begin(), parsed_error.end())
				);
			}
		}
	}

	void ModLoaderCore::setup_directories() {
		log_info("ModLoader version: {}. Current working dir: {}\n", version, std::filesystem::current_path().string());
		std::filesystem::create_directories(modloader_root_ / modloader_data_dir);
		std::filesystem::create_directories(modloader_root_ / modloader_data_dir / scripts_dir);
		std::filesystem::create_directories(modloader_root_ / modloader_data_dir / preinit_scripts_dir);
	}

	void ModLoaderCore::setup_modloader_hooks() {
		hook_api_function(L"kernel32.dll", "IsDebuggerPresent", is_debugger_present_hook, &orig_IsDebuggerPresent);

		if (get_rgss_base() == nullptr) {
			log_critical("Failed to get RGSS base address (RGSS301). ModLoader cannot work without it. Aborting hook setup.\n");
			return;
		}

		hook_function(load_data, &ModLoaderCoreHooks::load_data_hook, &ModLoaderCoreHooks::orig_load_data);
		hook_function(startup_scripts, &ModLoaderCoreHooks::startup_scripts_hook, &ModLoaderCoreHooks::orig_startup_scripts);

		for (auto& applier : hooks_appliers) {
			applier();
		}

		// remove restriction from "load_data" when executing game script to always load from encrypted "Game.rgss3a"
		patch_memory_as<int>(0xEBB4, 1);

		// change rgss_main to rgsssmain
		patch_memory_as<char>(0x1A7EF0, 's');

		log_info("Applied all base hooks\n");
	}

	void ModLoaderCore::clear_modloader_hooks() {
		// TODO:
	}

	void ModLoaderCore::setup_mod_loader_ruby_module() {
		//add_preinit_handler([this] {
			ruby_module_ = rb_define_module("ModLoader");
			register_ruby_method("hrfix_enabled", ModLoaderRubyModule::hrfix_enabled);
			register_ruby_method("fast_render_enabled", ModLoaderRubyModule::fast_render_enabled);
			register_ruby_method("controls_change_enabled", ModLoaderRubyModule::controls_change_enabled);
			register_ruby_method("version", ModLoaderRubyModule::version);
			register_ruby_method("data_directory", ModLoaderRubyModule::data_directory);
			register_ruby_method("config_get", ModLoaderRubyModule::config_get);
			register_ruby_method("version_major", ModLoaderRubyModule::version_major);
			register_ruby_method("version_minor", ModLoaderRubyModule::version_minor);

			register_ruby_method("log", &ModLoaderRubyModule::log_ruby);
		//});
	}

	GameFrame* ModLoaderCore::get_game() const {
		return *rgss_game;
	}

	int ModLoaderCore::execute_script(std::string_view script) const {
		return eval_rb_cstr_noerr(script.data());
	}

	int ModLoaderCore::execute_script(std::string_view script, std::string_view script_name, int& error) const {
		return eval_rb_cstr(script.data(), script_name.data(), std::addressof(error));
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

	RubyModException::RubyModException(RubyValue klass, const char* message) : klass_(klass), std::exception(message)
	{}

	RubyValue RubyModException::klass() const {
		return klass_;
	}

#define STRINGIFY_(a) #a
#define STRINGIFY(a) STRINGIFY_(a)

	constexpr std::string_view make_version_string() {
		return STRINGIFY(RM_MODLOADER_VERSION_MAJOR) "." STRINGIFY(RM_MODLOADER_VERSION_MINOR);
	}

#undef STRINGIFY_
#undef STRINGIFY
	
	constexpr std::string_view ModLoaderCore::version = make_version_string();
	std::shared_ptr<ModLoaderCore> mod_loader;
}