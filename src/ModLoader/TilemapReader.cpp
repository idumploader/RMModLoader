#include "TilemapReader.hpp"

#include <ranges>

using std::views::iota;

namespace rm_modloader::tilemap {

	// A autotile patterns
	constexpr std::array<glm::vec2[4], 48> autotile_origins_a = { {
		{ { 1.0f, 2.0f }, { 0.5f, 2.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 2.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 0.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 0.5f, 2.0f },
		  { 1.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 2.0f },
		  { 1.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 0.0f },
		  { 1.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 2.0f }, { 0.5f, 2.0f },
		  { 1.0f, 0.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 2.0f },
		  { 1.0f, 0.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 0.0f },
		  { 1.0f, 0.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 0.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 0.5f, 2.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 2.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 0.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 0.0f, 2.0f }, { 0.5f, 2.0f },
		  { 0.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 0.0f, 2.0f }, { 1.5f, 0.0f },
		  { 0.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 0.0f, 2.0f }, { 0.5f, 2.0f },
		  { 0.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 0.0f, 2.0f }, { 1.5f, 0.0f },
		  { 0.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 0.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 2.0f },
		  { 1.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 2.0f },
		  { 1.0f, 0.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 2.0f },
		  { 1.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 2.0f },
		  { 1.0f, 0.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 0.5f, 2.0f },
		  { 1.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 2.0f },
		  { 1.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 0.0f },
		  { 1.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 0.0f, 2.0f }, { 1.5f, 2.0f },
		  { 0.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 0.0f, 1.0f }, { 0.5f, 1.0f },
		  { 0.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 0.0f, 1.0f }, { 0.5f, 1.0f },
		  { 0.0f, 1.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 1.0f }, { 1.5f, 1.0f },
		  { 1.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 1.0f }, { 1.5f, 1.0f },
		  { 1.0f, 0.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 2.0f }, { 1.5f, 2.0f },
		  { 1.0f, 2.5f }, { 1.5f, 2.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 2.0f },
		  { 1.0f, 2.5f }, { 1.5f, 2.5f } },
		{ { 0.0f, 2.0f }, { 0.5f, 2.0f },
		  { 0.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 0.0f, 2.0f }, { 1.5f, 0.0f },
		  { 0.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 0.0f, 1.0f }, { 1.5f, 1.0f },
		  { 0.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 0.0f, 1.0f }, { 0.5f, 1.0f },
		  { 0.0f, 2.5f }, { 0.5f, 2.5f } },
		{ { 0.0f, 2.0f }, { 1.5f, 2.0f },
		  { 0.0f, 2.5f }, { 1.5f, 2.5f } },
		{ { 1.0f, 1.0f }, { 1.5f, 1.0f },
		  { 1.0f, 2.5f }, { 1.5f, 2.5f } },
		{ { 0.0f, 1.0f }, { 1.5f, 1.0f },
		  { 0.0f, 2.5f }, { 1.5f, 2.5f } },
		{ { 0.0f, 0.0f }, { 0.5f, 0.0f },
		  { 0.0f, 0.5f }, { 0.5f, 0.5f } },
	} };

	// B autotile patterns
	constexpr std::array<glm::vec2[4], 16> autotile_origins_b = { {
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 0.5f }, { 0.5f, 0.5f } },
		{ { 0.0f, 1.0f }, { 0.5f, 1.0f },
		  { 0.0f, 0.5f }, { 0.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 0.0f },
		  { 1.0f, 0.5f }, { 0.5f, 0.5f } },
		{ { 0.0f, 0.0f }, { 0.5f, 0.0f },
		  { 0.0f, 0.5f }, { 0.5f, 0.5f } },
		{ { 1.0f, 1.0f }, { 1.5f, 1.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 0.0f, 1.0f }, { 1.5f, 1.0f },
		  { 0.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 0.0f, 0.0f }, { 1.5f, 0.0f },
		  { 0.0f, 0.5f }, { 1.5f, 0.5f } },
		{ { 1.0f, 1.0f }, { 0.5f, 1.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 0.0f, 1.0f }, { 0.5f, 1.0f },
		  { 0.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 0.5f, 0.0f },
		  { 1.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 0.0f, 0.0f }, { 0.5f, 0.0f },
		  { 0.0f, 1.5f }, { 0.5f, 1.5f } },
		{ { 1.0f, 1.0f }, { 1.5f, 1.0f },
		  { 1.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 0.0f, 1.0f }, { 1.5f, 1.0f },
		  { 0.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 1.0f, 0.0f }, { 1.5f, 0.0f },
		  { 1.0f, 1.5f }, { 1.5f, 1.5f } },
		{ { 0.0f, 0.0f }, { 1.5f, 0.0f },
		  { 0.0f, 1.5f }, { 1.5f, 1.5f } },
	} };

	/**
	 * Create autotile wit 4 primitives with given pattern and pattern source
	 */
	void read_autotile(TilemapReader& reader, const glm::vec3& origin, const glm::vec2& tex_offset,
		int pattern_id, std::span<const glm::vec2[4]> sources, int texture_index, const glm::vec2& animation_stride) {
		if (pattern_id >= sources.size()) {
			return;
		}

		static constexpr glm::vec2 index_offsets[] = {
			{ 0.0f, 0.0f },
			{ 16.0f, 0.0f },
			{ 0.0f, 16.0f },
			{ 16.0f, 16.0f }
		};

		for (int i : iota(0, 4)) {
			const glm::vec2& pattern_tex_offset = sources[pattern_id][i];

			glm::vec2 tile_final_tex_offset = pattern_tex_offset + tex_offset;
			tile_final_tex_offset.y -= 0.5f; // TODO: find out why this needs to be added

			glm::vec3 new_origin = origin + glm::vec3(index_offsets[i], 0.0f);
			reader.on_primitive(
				new_origin,
				glm::vec2(0.5f),
				tile_final_tex_offset,
				texture_index,
				animation_stride // TODO: check if for all tiles
			);
		}
	}

	/**
	 * Create A autotile with 4 primitives
	 */
	void read_autotile_a(TilemapReader& reader, const glm::vec3& origin,
		const glm::vec2& tex_offset, int pattern_id, int texture_index, const glm::vec2& animation_stride) {
		read_autotile(reader, origin, tex_offset, pattern_id, autotile_origins_a, texture_index, animation_stride);
	}

	/**
	 * Create B autotile with 4 primitives
	 */
	void read_autotile_b(TilemapReader& reader, const glm::vec3& origin,
		const glm::vec2& tex_offset, int pattern_id, int texture_index) {
		read_autotile(reader, origin, tex_offset, pattern_id, autotile_origins_b, texture_index);
	}

	/**
	 * Create waterfall with 2 primitives
	 */
	void read_autotile_c(TilemapReader& reader, const glm::vec3& origin, const glm::vec2& tex_offset, int pattern_id) {
		if (pattern_id > 3) {
			return;
		}

		static constexpr glm::vec2 autotile_rects_c[][2] = {
			{ { 1.0f, 0.0f }, { 0.5f, 0.0f } },
			{ { 0.0f, 0.0f }, { 0.5f, 0.0f } },
			{ { 1.0f, 0.0f }, { 1.5f, 0.0f } },
			{ { 0.0f, 0.0f }, { 1.5f, 0.0f } }
		};

		for (auto i : iota(0, 2)) {
			glm::vec2 tile_tex_offset_c = autotile_rects_c[pattern_id][i];

			reader.on_primitive(
				origin + glm::vec3(i * 16.f, 0.0f, 0.0f),
				glm::vec2(0.5f, 1.0f),
				tex_offset + tile_tex_offset_c,
				TilesetIndex::tileset_A1,
				glm::vec2(0.0f, 1.0f)
			);
		}
	}

	/**
	 * B, C, D, E tile is basic custom tile.
	 * @todo handle is_over_player
	 */
	void read_tile_bcde(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin, bool is_over_player) {
		int ob = tile_id / (0x8 * 0x10);
		int tex_x = (tile_id % 8) + (ob % 2) * 8;
		int tex_y = (tile_id >> 3) % 16 + (ob / 2) * 16;

		reader.on_primitive(
			origin,
			glm::vec2(1.f),
			glm::vec2(tex_x, tex_y),
			tile_id / 0x100 + 5,
			glm::vec2(0.f)
		);
	}

	/**
	 * @todo check for right part offsets
	 * 
	 * A3 tile is an ocean, pond, lava, etc. tiles. Tileset contains parts with pools and waterfalls
	 * Belongs to autotiles, and is animated.
	 * Pool part is 6x3, each animation part is 2x3, animation stride (2, 0). Waterfall part is 2x3
	 * P - pool, W - Waterfall
	 * P0,1 - Pool 0, animation frame 1
	 *  -----------------------------------------------------
	 * | P0,1 | P0,2 |  P0,3 | ** | P3,1 | P3,2 |  P3,3 | W0 |
	 *  -----------------------------------------------------
	 * | P1,1 | P1,2 |  P1,3 | ** | P4,1 | P4,2 |  P4,3 | W1 |
	 *  -----------------------------------------------------
	 * | P5,1 | P5,2 |  P5,3 | W3 | P7,1 | P7,2 |  P7,3 | W5 |
	 *  -----------------------------------------------------
	 * | P6,1 | P6,2 |  P6,3 | W4 | P8,1 | P8,2 |  P8,3 | W6 |
	 *  -----------------------------------------------------
	 * 
	 * First 2 bits are x index, and other top bits are y index
	 */
	void read_tile_a1(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin) {
		tile_id -= 0x800;

		auto [pattern_id, autotile_id] = tile_id_to_autotile_pattern(tile_id);

		// Missed offsets?
		static const glm::vec2 is_ac_vec(-1, -1);
		static const glm::vec2 tex_offsets[] = {
			{ 0, 0 },
			{ -2, -2 }, // undefined
			{ 8, 0 },
			is_ac_vec,
			{ 0, 3 },
			{ -2, -2 }, // undefined
			{ 8, 3 },
			is_ac_vec,

			{ 0, 6 },
			is_ac_vec,
			{ 8, 6 },
			is_ac_vec,
			{ 0, 9 },
			is_ac_vec,
			{ 8, 9 },
			is_ac_vec
		};

		const glm::vec2& tex_offset = tex_offsets[autotile_id]; // TODO: check for overflow

		if (tex_offset == is_ac_vec) {
			int autotile_c_id = (autotile_id - 5) / 2;

			// Missed offsets?
			static const glm::vec2 tex_offsets_c[] = {
				{ 14, 0 },
				{ 14, 3 },
				{ 6, 6 },
				{ 14, 6 },
				{ 6, 9 },
				{ 14, 9 }
			};

			const glm::vec2& tex_offset = tex_offsets_c[autotile_c_id];
			read_autotile_c(reader, origin, tex_offset, pattern_id);
			return;
		}

		read_autotile_a(
			reader,
			origin,
			tex_offset,
			pattern_id,
			TilesetIndex::tileset_A1,
			glm::vec2(2.0f, 0.0f)
		);
	}

	/**
	 * A3 tile is a terraing tile. Tileset is 16x12 and contains ground, fences, etc.
	 * Belongs to autotiles.
	 * Tileset part is 2x3
	 *  -----------------
	 * | 0 | 1 | ... | 7 |
	 *  -----------------
	 * | 0 | 1 | ... | 7 |
	 *  -----------------
	 * |         ...     |
	 *  -----------------
	 *
	 * First 3 bits are X index of floor tileset part, and top bits are Y index
	 */
	void read_tile_a2(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin, bool is_table) {
		tile_id -= 0xB00;

		auto [pattern_id, autotile_id] = tile_id_to_autotile_pattern(tile_id);

		glm::vec2 tex_offset((autotile_id % 8) * 2, (autotile_id / 8) * 3);

		// is table?
		if (is_table) {

		}
		else {
			read_autotile_a(reader, origin, tex_offset, pattern_id, TilesetIndex::tileset_A2);
		}
	}

	/**
	 * A3 tile is a building tile. Tileset is 16x8 and contains roof tiles at top, and wall tiles bottom to roof.
	 * Belongs to autotiles.
	 * Floor part are 2x2, and wall is 2x2
	 * R - floor tile, W - wall tile
	 *  --------------------
	 * | R0 | R1 | ... | R7 |
	 *  --------------------
	 * | W0 | W1 | ... | W7 |
	 *  --------------------
	 * |        ...         |
	 *  --------------------
	 *
	 * First 3 bits are X index of floor tileset part, and top bits are Y index
	 */
	void read_tile_a3(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin) {
		tile_id -= 0x1100;

		auto [pattern_id, autotile_id] = tile_id_to_autotile_pattern(tile_id);

		glm::vec2 tex_offset((autotile_id % 8) * 2, (autotile_id / 8) * 2);

		read_autotile_b(reader, origin, tex_offset, pattern_id, TilesetIndex::tileset_A3);
	}

	/**
	 * A4 tile is a wall/floor tile. Tileset is 16x15 and contains floor tiles at top, and wall tiles bottom to floor.
	 * Belongs to autotiles.
	 * Floor part are 2x3, and wall is 2x2
	 * F - floor tile, W - wall tile
	 *  --------------------
	 * | F0 | F1 | ... | F7 |
	 *  --------------------
	 * | W0 | W1 | ... | W7 |
	 *  --------------------
	 * |        ...         |
	 *  --------------------
	 * 
	 * First 3 bits are X index of floor tileset part, and top bits are Y index
	 */
	void read_tile_a4(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin) {
		tile_id -= 0x1700;

		auto [pattern_id, autotile_id] = tile_id_to_autotile_pattern(tile_id);

		static constexpr float offset_y[] = { 0, 3, 5, 8, 10, 13 };

		glm::vec2 tex_offset((autotile_id % 8) * 2, offset_y[autotile_id / 8]);

		if ((autotile_id / 8) % 2 == 0) {
			read_autotile_a(reader, origin, tex_offset, pattern_id, TilesetIndex::tileset_A4);
		}
		else {
			read_autotile_b(reader, origin, tex_offset, pattern_id, TilesetIndex::tileset_A4);
		}
	}

	/**
	 * A5 tile are basic and constructed only with 1 part
	 * bottom 3-bits of tile are x texture offset, and other top bits are y texture offset
	 */
	void read_tile_a5(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin) {
		tile_id -= 0x600;

		reader.on_primitive(
			origin,
			glm::vec2(1.),
			glm::vec2(tile_id % 8, tile_id / 8),
			TilesetIndex::tileset_A5,
			glm::vec2(0.f)
		);
	}

	void read_tile_primitives(TilemapReader& reader, int16_t tile_id, int16_t flag, const glm::vec3& origin) {
		bool is_over_player = flag & (1 << 4);
		bool is_table = flag & (1 << 7);

		if (tile_id < 0x400) {
			read_tile_bcde(reader, tile_id, origin, is_over_player);
		}
		else if (tile_id >= 0x600 && tile_id < 0x680) {
			read_tile_a5(reader, tile_id, origin);
		}
		else if (tile_id >= 0x800 && tile_id < 0xB00) {
			read_tile_a1(reader, tile_id, origin);
		}
		else if (tile_id >= 0xB00 && tile_id < 0x1100) {
			read_tile_a2(reader, tile_id, origin, is_table);
		}
		else if (tile_id < 0x1700) {
			read_tile_a3(reader, tile_id, origin);
		}
		else if (tile_id < 0x2000) {
			read_tile_a4(reader, tile_id, origin);
		}
		else {
			// ...
		}
	}

	void read_shadow_primitives(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin) {
		tile_id = tile_id & 0xF;
		if (tile_id == 0) {
			return;
		}

		reader.on_shadow_primitive(
			origin,
			glm::vec2(tile_id % 4, tile_id / 4)
		);
	}

	void read_tilemap_primitives(TilemapReader& reader, const RxTilemap* tilemap, int z_offset) {
		size_t width = tilemap->width;
		size_t height = tilemap->height;
		size_t depth = tilemap->depth;

		// TODO: Maybe fix shadows drawn above the top layer
		// Read 2 bottom layers and 1 top layer
		for (size_t z = 0; z < depth - 1; ++z) {
			for (size_t y = 0; y < height; ++y) {
				for (size_t x = 0; x < width; ++x) {
					size_t index = z * height * width + y * width + x;
					int16_t tile_id = tilemap->map_data[index];
					int16_t tile_flag = tile_id < tilemap->flags_count ? tilemap->flags[tile_id] : 0;

					read_tile_primitives(reader, tile_id, tile_flag, glm::vec3(x * 32, y * 32, z_offset + z));
				}
			}
		}

		// read shadow layer
		for (size_t y = 0; y < height; ++y) {
			for (size_t x = 0; x < width; ++x) {
				const size_t z = (depth - 1);
				size_t index = z * height * width + y * width + x;
				int16_t tile_id = tilemap->map_data[index];

				read_shadow_primitives(reader, tile_id, glm::vec3(x * 32, y * 32, z_offset + z));
			}
		}
	}
};