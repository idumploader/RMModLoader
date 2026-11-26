#pragma once

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <span>

namespace rm_modloader {

// Writes the engine's existing 32-bit DIB layout unchanged. Callers decide
// whether an unavailable output file is an error or a best-effort debug dump.
inline bool write_surface_bitmap(const std::filesystem::path& path,
    int32_t width, int32_t height, const uint8_t* bits) {
#pragma pack(push, 1)
    struct BmpHeader {
        char signature[2] = { 'B', 'M' };
        uint32_t file_size = 54;
        uint32_t reserved = 0;
        uint32_t pixel_offset = 54;
    } header;
    struct BmpInfoHeader {
        uint32_t header_size = 40;
        int32_t width = 0;
        int32_t height = 0;
        uint16_t planes = 1;
        uint16_t depth = 32;
        uint32_t compression = 0;
        uint32_t data_size = 0;
        int32_t horizontal_resolution = 0;
        int32_t vertical_resolution = 0;
        uint32_t color_entries = 0;
        uint32_t important_colors = 0;
    } info;
#pragma pack(pop)
    static_assert(sizeof(BmpHeader) == 14);
    static_assert(sizeof(BmpInfoHeader) == 40);

    if (width == 0 || height == 0) return true;
    info.width = width;
    info.height = height;
    std::span<const uint8_t> pixels(bits, width * height * 4);
    header.file_size = 54 + static_cast<uint32_t>(pixels.size_bytes());
    std::ofstream stream(path, std::ios::binary);
    if (!stream.is_open()) return false;
    stream.write(reinterpret_cast<const char*>(&header), sizeof(header));
    stream.write(reinterpret_cast<const char*>(&info), sizeof(info));
    stream.write(reinterpret_cast<const char*>(pixels.data()), pixels.size_bytes());
    return true;
}

} // namespace rm_modloader
