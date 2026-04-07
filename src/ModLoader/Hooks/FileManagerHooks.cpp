#include "FileManagerHooks.hpp"
#include "../ModLoader.hpp"
#include "../Hook.hpp"
#include "../RMGlobal.hpp"

#include <fstream>

#pragma comment(lib, "Winmm.lib")

namespace rm_modloader {
	static RubyValue file_manager_module;

	struct MemoryFilePtrDeleter {
		void operator()(RxMemoryFile* memory_file) const noexcept {
			(memory_file->*rx_memory_file_dtx)(true);
		}
	};

	using MemoryFilePtr = std::unique_ptr<RxMemoryFile, MemoryFilePtrDeleter>;

	static void dump_surface(Surface* surface, const std::filesystem::path& path) {
#pragma pack(push, 1)
		struct BmpHeader {
			char bitmapSignatureBytes[2] = { 'B', 'M' };
			uint32_t sizeOfBitmapFile = 54 + 0;
			uint32_t reservedBytes = 0;
			uint32_t pixelDataOffset = 54;
		} bmp_header;

		struct BmpInfoHeader {
			uint32_t sizeOfThisHeader = 40;
			int32_t width = 0; // in pixels
			int32_t height = 0; // in pixels
			uint16_t numberOfColorPlanes = 1; // must be 1
			uint16_t colorDepth = 32;
			uint32_t compressionMethod = 0;
			uint32_t rawBitmapDataSize = 0; // generally ignored
			int32_t horizontalResolution = 0; // in pixel per meter
			int32_t verticalResolution = 0; // in pixel per meter
			uint32_t colorTableEntries = 0;
			uint32_t importantColors = 0;
		} bmp_info_header;
#pragma pack(pop)

		bmp_info_header.width = surface->info.bitmap->bmiHeader.biWidth;
		bmp_info_header.height = surface->info.bitmap->bmiHeader.biHeight;

		if (bmp_info_header.width == 0 || bmp_info_header.height == 0) {
			return;
		}

		std::span<uint8_t> surface_span(surface->image.bits, bmp_info_header.width * bmp_info_header.height * 4);

		bmp_header.sizeOfBitmapFile = 54 + surface_span.size_bytes();

		std::ofstream file_stream(path, std::ios::binary);
		if (!file_stream.is_open()) {
			throw std::runtime_error("Failed to create output file");
		}

		file_stream.write(reinterpret_cast<char*>(&bmp_header), sizeof(BmpHeader));
		file_stream.write(reinterpret_cast<char*>(&bmp_info_header), sizeof(BmpInfoHeader));

		file_stream.write(reinterpret_cast<char*>(surface_span.data()), surface_span.size_bytes());
	}

	static Surface* get_value_surface(RubyValue value) {
		RubyValue* rx_graphics_class = mod_loader->at_base_offset_as<RubyValue*>(0x261B3C);

		if (rb_type(value) == RUBY_T_DATA
			&& rb_get_value_klass(value) != *rx_bitmap_class) {
			return get_rb_data_data<RxBitmap>(value)->surface;
		}
		else if (rb_type(value) == RUBY_T_MODULE
			&& rb_get_value_klass(value) != *rx_graphics_class) {
			return mod_loader->get_game()->screen->surface;
		}
		else {
			rb_raise(*ruby_error_arg_error, "Expected bitmap, Graphics");
			return nullptr; // to fix warning
		}
	}

	struct FileManagerModule {

		static RubyValue __cdecl list_files(RubyValue module) {
			int file_count = (file_repository->*file_repository_file_count)();
			RubyValue files_array = rb_ary_new2(file_count);

			for (int i = 0; i < file_count; ++i) {
				RepositoryFileInfo* file_info = (file_repository->*file_repository_file_at_index)(i);
				RubyValue filename_value = rb_str_new_cstr(file_info->filename);
				
				rb_ary_push(files_array, filename_value);
			}

			return files_array;
		}

		static RubyValue __cdecl read_file(RubyValue module, RubyValue path_value) {
			std::string_view path = rb_get_string_data(&path_value);

			auto game_file = MemoryFilePtr(read_into_rx_memory_file(path.data()));
			if (!game_file) {
				rb_raise(*ruby_error_arg_error, "Failed to open file");
				return ruby_nil;
			}

			LONG file_size = mmioSeek(game_file->mm_io, 0, SEEK_END);
			std::string file_data(file_size, 0);

			mmioSeek(game_file->mm_io, 0, SEEK_SET);
			mmioRead(game_file->mm_io, file_data.data(), file_size);

			RubyValue data_value = rb_str_new(file_data.c_str(), file_data.length());

			return data_value;
		}

		static RubyValue __cdecl dump_as_bmp(RubyValue module, RubyValue bitmap_value, RubyValue path_value) {
			Surface* surface = get_value_surface(bitmap_value);
			std::string_view path = rb_get_string_data(&path_value);

			try {
				dump_surface(surface, path);
			}
			catch (std::runtime_error& e) {
				mod_loader->log_error("Failed to dump bitmap surface: {}\n", e.what());
				return ruby_false;
			}

			return ruby_true;
		}
	};

	void apply_file_manager_hooks() {
		mod_loader->add_preinit_handler([] {
			mod_loader->register_ruby_method("list_files",  FileManagerModule::list_files);
			mod_loader->register_ruby_method("read_file",   FileManagerModule::read_file);
			mod_loader->register_ruby_method("dump_as_bmp", FileManagerModule::dump_as_bmp);
		});
	}
}