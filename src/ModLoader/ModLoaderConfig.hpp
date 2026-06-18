#pragma once
#include <filesystem>
#include <nlohmann/json.hpp>

namespace rm_modloader {
	class ModLoaderConfig {
	public:
		ModLoaderConfig();
		ModLoaderConfig(const std::filesystem::path& filepath);

		/**
		 * Check if key contains in config
		 * @param key Key name to check
		 * @return True if the key exists, false otherwise
		 */
		bool contains(std::string_view key) const;

		/**
		 * Get the value with key. Throw an error if it doesn't exist
		 * @param key Key name to check
		 * @throws std::exception If the key doesn't exist
		 * @return Config value reference
		 */
		const nlohmann::json& at(std::string_view key) const;

		/**
		 * Get the value with key, nothrow
		 * @param key Key name to check
		 * @return Config value pointer, or nullptr if it doesn't exist
		 */
		const nlohmann::json* get(std::string_view key) const noexcept;

	private:
	
		nlohmann::json config_;
	};
}