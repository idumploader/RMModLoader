#include "Logger.hpp"
#define WIN32_MEAN_AND_LEAN
#include <Windows.h>

namespace rm_modloader {
	static HANDLE logger_output_handle = INVALID_HANDLE_VALUE;
	LogLevel Logger::current_level_ = LogLevel::Info;

	static std::string_view get_log_level_color(LogLevel level) {
		switch (level) {
		case LogLevel::Debug:
			return "";
		case LogLevel::Info:
			return "";
		case LogLevel::Warning:
			return "";
		case LogLevel::Error:
			return "";
		default:
			return "";
		}
	}

	int Logger::init(std::string_view output_name) noexcept {
		if (logger_output_handle != INVALID_HANDLE_VALUE) {
			return -1;
		}
		logger_output_handle = CreateFileA(output_name.data(), FILE_WRITE_ACCESS, 0, nullptr, OPEN_EXISTING, 0, nullptr);
		return logger_output_handle != INVALID_HANDLE_VALUE ? 0 : -1;
	}

	int Logger::deinit() noexcept {
		if (logger_output_handle == INVALID_HANDLE_VALUE) {
			return -1;
		}
		if (!CloseHandle(logger_output_handle)) {
			return -1;
		}
		logger_output_handle = INVALID_HANDLE_VALUE;
		return 0;
	}

	void Logger::set_log_level(LogLevel level) noexcept {
		current_level_ = level;
	}

	void Logger::log(LogLevel level, std::string_view message) {
		if (logger_output_handle == INVALID_HANDLE_VALUE) {
			return;
		}
		if (level >= current_level_) {
			DWORD written;
			WriteFile(logger_output_handle, message.data(), message.size(), &written, nullptr);
		}
	}

	void Logger::debug(std::string_view message) {
		log(LogLevel::Debug, message);
	}

	void Logger::info(std::string_view message) {
		log(LogLevel::Info, message);
	}

	void Logger::warning(std::string_view message) {
		log(LogLevel::Warning, message);
	}

	void Logger::error(std::string_view message) {
		log(LogLevel::Error, message);
	}

	void Logger::critical(std::string_view message) {
		log(LogLevel::Critical, message);
	}
};