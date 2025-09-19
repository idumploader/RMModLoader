#include "ModLoaderConfig.hpp"
#include "ModLoader.hpp"

#include <fstream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace rm_modloader {
	ModLoaderConfig::ModLoaderConfig() :
		required_width_(1920),
		required_height_(1000),
		hrfix_enabled_(true)
	{

	}

	ModLoaderConfig::ModLoaderConfig(const std::filesystem::path& filepath) : ModLoaderConfig() {
		std::ifstream config_is(filepath);
		json config = json::parse(config_is);

		// TODO: not trust to mod loader inited
		required_width_ = config.at("width");
		required_height_ = config.at("height");
		hrfix_enabled_ = config.at("hrfix_enable");
	}
	int ModLoaderConfig::get_required_width() const {
		return required_width_;
	}
	int ModLoaderConfig::get_required_height() const {
		return required_height_;
	}
	int ModLoaderConfig::is_hrfix_enabled() const {
		return hrfix_enabled_;
	}
}