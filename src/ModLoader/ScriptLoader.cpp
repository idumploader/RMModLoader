#include "ModLoader.hpp"
#include "ScriptOrder.hpp"
#include <array>
#include <cwctype>
#include <fstream>

namespace rm_modloader {
	void ModLoaderCore::execute_all_user_scripts_in(const std::filesystem::path& scripts_dir) const {
		const auto indexed_entries = scripts::ordered_entries(scripts_dir, [this](const auto& entry) {
			log_warning("file {} has invalid enumeration filename syntax (should be \"dddd - *.rb\"). Placing at the end.\n", entry.path().filename().string());
		});

		for (auto& indexed_entry : indexed_entries) {
			const std::filesystem::directory_entry& entry = indexed_entry.second;
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
					return static_cast<char>(std::iswprint(c) || c == L'\n' ? c : L'?');
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

}
