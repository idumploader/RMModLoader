#pragma once
#include <filesystem>
#include <nlohmann/json.hpp>

namespace rm_modloader {
	class ModLoaderConfig {
	public:
		ModLoaderConfig();
		ModLoaderConfig(const std::filesystem::path& filepath);

		int get_required_width() const;
		int get_required_height() const;
		bool is_hrfix_enabled() const;
		bool is_fast_render_enabled() const;
		bool is_controls_change_enabled() const;

		bool contains(std::string_view key) const;
		const nlohmann::json& at(std::string_view key) const;

	private:
		int required_width_;
		int required_height_;
		bool hrfix_enabled_;
		bool fast_render_enabled_;
		bool controls_change_enabled_;
	
		nlohmann::json config_;
	};
}