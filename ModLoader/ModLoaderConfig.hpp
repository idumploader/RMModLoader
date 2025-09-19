#pragma once
#include <filesystem>

namespace rm_modloader {
	class ModLoaderConfig {
	public:
		ModLoaderConfig();
		ModLoaderConfig(const std::filesystem::path& filepath);

		int get_required_width() const;
		int get_required_height() const;
		int is_hrfix_enabled() const;

	private:
		int required_width_;
		int required_height_;
		int hrfix_enabled_;
	};
}