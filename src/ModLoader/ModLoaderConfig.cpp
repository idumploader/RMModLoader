#include "ModLoaderConfig.hpp"
#include "ModLoader.hpp"

#include <fstream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace rm_modloader {
	ModLoaderConfig::ModLoaderConfig() :
		required_width_(1920),
		required_height_(1000),
		hrfix_enabled_(true),
		fast_render_enabled_(false),
		controls_change_enabled_(true)
	{

	}

	ModLoaderConfig::ModLoaderConfig(const std::filesystem::path& filepath) : ModLoaderConfig() {
		std::ifstream config_is(filepath);
		config_ = json::parse(config_is);

		required_width_ = config_.at("width");
		required_height_ = config_.at("height");
		hrfix_enabled_ = config_.at("hrfix_enable");
		fast_render_enabled_ = config_.at("fast_render");
		controls_change_enabled_ = config_.at("controls_change");
	}

	int ModLoaderConfig::get_required_width() const {
		return required_width_;
	}

	int ModLoaderConfig::get_required_height() const {
		return required_height_;
	}

	bool ModLoaderConfig::is_hrfix_enabled() const {
		return hrfix_enabled_;
	}

	bool ModLoaderConfig::is_fast_render_enabled() const {
		return fast_render_enabled_;
	}

	bool ModLoaderConfig::is_controls_change_enabled() const {
		return controls_change_enabled_;
	}

	bool ModLoaderConfig::contains(std::string_view key) const {
		return config_.contains(key);
	}

	const nlohmann::json& ModLoaderConfig::at(std::string_view key) const {
		return config_.at(key);
	}
}