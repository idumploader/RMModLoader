#pragma once
#include <string_view>
#include <optional>

namespace rm_modloader {
	enum class LogLevel {
		Debug,
		Info,
		Warning,
		Error,
		Critical,
		Silent
	};

	class Logger {
	public:
		/**
		 * Initialize logger with given output file name
		 * @param output_name File name to log to
		 * @return 0 on success, -1 on failure
		 */
		static int init(std::optional<std::string_view> output_name) noexcept;

		/**
		 * Deinitialize logger
		 * @return 0 on success, -1 on failure
		 */
		static int deinit() noexcept;

		/**
		 * Set logger output log level. Logs with level lower than current log level will be ignored
		 * @param level New log level
		 */
		static void set_log_level(LogLevel level) noexcept;

		/**
		 * Log message with given level.
		 * @param level Log level
		 * @param message Message to log
		 */
		static void log(LogLevel level, std::string_view message);

		/**
		 * Log message with debug level.
		 * @param message Message to log
		 */
		static void debug(std::string_view message);

		/**
		 * Log message with info level.
		 * @param message Message to log
		 */
		static void info(std::string_view message);

		/**
		 * Log message with warning level.
		 * @param message Message to log
		 */
		static void warning(std::string_view message);

		/**
		 * Log message with error level.
		 * @param message Message to log
		 */
		static void error(std::string_view message);

		/**
		 * Log message with critical level.
		 * @param message Message to log
		 */
		static void critical(std::string_view message);

	private:
		static LogLevel current_level_;
	};
}