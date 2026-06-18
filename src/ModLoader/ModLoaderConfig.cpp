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