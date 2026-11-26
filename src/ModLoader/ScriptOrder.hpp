#pragma once
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

namespace rm_modloader::scripts {
    // Numeric priorities are the established extension contract. Ties use the
    // complete filename so directory enumeration cannot change alias chains.
    template<typename InvalidName>
    auto ordered_entries(const std::filesystem::path& directory, InvalidName&& invalid_name) {
        using Entry = std::filesystem::directory_entry;
        std::vector<std::pair<int64_t, Entry>> entries;
        for (const auto& entry : std::filesystem::directory_iterator(directory)) {
            if (entry.is_directory() || entry.path().extension() != ".rb") continue;
            const auto filename = entry.path().filename().string();
            const auto delimiter = filename.find(" - ");
            auto priority = (std::numeric_limits<int64_t>::max)();
            bool valid = false;
            if (delimiter != std::string::npos) {
                std::istringstream input(filename.substr(0, delimiter));
                int64_t parsed;
                if (input >> parsed) { priority = parsed; valid = true; }
            }
            if (!valid) invalid_name(entry);
            entries.emplace_back(priority, entry);
        }
        std::sort(entries.begin(), entries.end(), [](const auto& left, const auto& right) {
            if (left.first != right.first) return left.first < right.first;
            return left.second.path().filename().native() < right.second.path().filename().native();
        });
        return entries;
    }
}
