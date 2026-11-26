#include "ModLoaderConfig.hpp"
#include "ModLoader.hpp"

#include <fstream>
#include <iterator>
#include <string>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace rm_modloader {
	ModLoaderConfig::ModLoaderConfig()
	{

	}

	ModLoaderConfig::ModLoaderConfig(const std::filesystem::path& filepath) : ModLoaderConfig() {
		std::ifstream config_is(filepath);
		if (!config_is && std::filesystem::exists(filepath))
			throw std::runtime_error("Cannot read ModLoader config");
		std::string content((std::istreambuf_iterator<char>(config_is)), std::istreambuf_iterator<char>());

		// An absent or empty mod_loader.json is a valid "use all defaults" state, not
		// an error: leave config_ empty so every get() falls back to its default.
		if (content.find_first_not_of(" \t\r\n") == std::string::npos) {
			return;
		}

		config_ = json::parse(content);
	}

	bool ModLoaderConfig::contains(std::string_view key) const {
		return config_.contains(key);
	}

	void ModLoaderConfig::save_overrides(const std::filesystem::path& filepath, const json& values) {
		ModLoaderConfig latest(filepath);
		json updated = latest.config_.is_null() ? json::object() : latest.config_;
		if (!updated.is_object()) throw std::runtime_error("ModLoader config must be a JSON object");
		updated.update(values);
		auto temporary = filepath;
		temporary += L".tmp." + std::to_wstring(GetCurrentProcessId());
		try {
			std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
			output.exceptions(std::ios::failbit | std::ios::badbit);
			output << updated.dump(2) << '\n';
			output.close();
			if (!MoveFileExW(temporary.c_str(), filepath.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
				throw std::system_error(GetLastError(), std::system_category(), "Save ModLoader config");
		} catch (...) {
			std::error_code ignored;
			std::filesystem::remove(temporary, ignored);
			throw;
		}
	}

	const nlohmann::json& ModLoaderConfig::at(std::string_view key) const {
		return config_.at(key);
	}
	const nlohmann::json* ModLoaderConfig::get(std::string_view key) const noexcept {
		if (!contains(key)) {
			return nullptr;
		}
		return std::addressof(at(key));
	}
}
