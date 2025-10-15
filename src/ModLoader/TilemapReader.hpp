#pragma once
#include "RMClasses.hpp"

#include <glm/vec2.hpp>
#include <glm/vec3.hpp>
#include <array>
#include <span>

/*
	REFERENCE: https://github.com/mkxp-z/mkxp-z/src/display/gl/tileatlasvx.cpp
*/

namespace rm_modloader::tilemap {
	constexpr glm::vec2 autotile_origin_invalid(-1.0f);

	struct TilesetIndex {
		static constexpr int tileset_A1 = 0; // Tileset of ocean, pond, lava, etc. Animated
		static constexpr int tileset_A2 = 1; // Tileset for terrain etc. 
		static constexpr int tileset_A3 = 2; // Tileset of buildings
		static constexpr int tileset_A4 = 3; // Tileset of walls
		static constexpr int tileset_A5 = 4; // Others tileset
		static constexpr int tileset_B = 5; // Others tileset. Top Layer
		static constexpr int tileset_C = 6; // Others tileset. Top Layer
		static constexpr int tileset_D = 7; // Others tileset. Top Layer
		static constexpr int tileset_E = 8; // Others tileset. Top Layer

		static constexpr int shadow = -1; // Shadow tile
	};

	// Array of patterns for autotiles. Used in @see read_autotile
	extern const std::array<glm::vec2[4], 48> autotile_origins_a;
	// Array of patterns for autotiles. Used in @see read_autotile
	extern const std::array<glm::vec2[4], 16> autotile_origins_b;

	/**
	 * Get the autotile ID, and pattern ID from tile ID
	 * @return Pair { autotile ID, pattern ID }
	 */
	inline std::pair<int, int> tile_id_to_autotile_pattern(int tile_id) {
		return { tile_id % 0x30, tile_id / 0x30 };
	}

	/**
	 * Reader for all the 'read_*' functions
	 */
	struct TilemapReader {
		virtual ~TilemapReader() = default;

		/**
		 * Called when read primitive (tile or it's part). @see read_tilemap_primitives
		 * @param origin 3D Coordinates of the tile in *pixels*
		 * @param zoom 2D Tile relative scale, default (1, 1)
		 * @param tex_offset 2D Texture offset inside tileset texture in *tiles*
		 * @param texture_index Tileset texture index inside RxTilemap::tilesets_surfaces. @see TilesetIndex
		 * @param animation_stride 2D Offset from 'tex_offset' to next animation frame. All animation tiles are equally spaced
		 */
		virtual void on_primitive(const glm::vec3& origin, const glm::vec2& zoom, const glm::vec2& tex_offset, int texture_index, const glm::vec2& animation_stride) = 0;

		/**
		 * Called when shadow tile primitive. They are a top layer primitives
		 * @param origin 3D Coordinates of the tile in *pixels*
		 * @param tex_offset 2D Texture offset inside shadow tileset texture in *tiles*
		 */
		virtual void on_shadow_primitive(const glm::vec3& origin, const glm::vec2& tex_offset) = 0;
	};

	/**
	 * Read 4 primitives of an autotile with pattern at specific location and texture offset.
	 * This tiles are constructed by mixing quaters of tiles in specific order taken from 'sources'
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param origin 3D Coordinates of this tile
	 * @param tex_offset Tileset texture offset of this tile
	 * @param pattern_id The pattern id used to lookup a pattern inside 'sources'
	 * @param sources Array of patterns indexed by 'pattern_id'. @ref autotile_origins_a, @ref autotile_origins_b
	 * @param texture_index Tileset texture index inside RxTilemap::tilesets_surfaces. @see TilesetIndex
	 * @param animation_stride Optional 2D offset of animation frames inside tileset texture
	 */
	extern void read_autotile(TilemapReader& reader, const glm::vec3& origin, const glm::vec2& tex_offset,
		int pattern_id, std::span<const glm::vec2[4]> sources, int texture_index, const glm::vec2& animation_stride = { 0, 0 });

	/**
	 * Read 4 primitives of an autotile with pattern at specific location and texture offset.
	 * Wrapper of @ref read_autotile, passes an @ref autotile_origins_a
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param origin 3D Coordinates of this tile
	 * @param tex_offset Tileset texture offset of this tile
	 * @param pattern_id The pattern id used to lookup the autotile pattern
	 * @param texture_index Tileset texture index inside RxTilemap::tilesets_surfaces. @see TilesetIndex
	 * @param animation_stride Optional 2D offset of animation frames inside tileset texture
	 */
	extern void read_autotile_a(TilemapReader& reader, const glm::vec3& origin,
		const glm::vec2& tex_offset, int pattern_id, int texture_index, const glm::vec2& animation_stride = { 0, 0 });

	/**
	 * Read 4 primitives of an autotile with pattern at specific location and texture offset.
	 * Wrapper of @ref read_autotile, passes an @ref autotile_origins_b
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param origin 3D Coordinates of this tile
	 * @param tex_offset Tileset texture offset of this tile
	 * @param pattern_id The pattern id used to lookup the autotile pattern
	 * @param texture_index Tileset texture index inside RxTilemap::tilesets_surfaces. @see TilesetIndex
	 */
	extern void read_autotile_b(TilemapReader& reader, const glm::vec3& origin,
		const glm::vec2& tex_offset, int pattern_id, int texture_index);

	/**
	 * Read 2 primitives of an autotile, splited by x-axis. Only used by "waterfall" tiles
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param origin 3D Coordinates of this tile
	 * @param tex_offset Tileset texture offset of this tile
	 * @param pattern_id The pattern id used to lookup the autotile pattern
	 */
	extern void read_autotile_c(TilemapReader& reader, const glm::vec3& origin, const glm::vec2& tex_offset, int pattern_id);

	/**
	 * Read B, C, D, E tilesets tile. It is basic tile, and usually a top layer tile
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 * @param is_over_player Flag to indicate that the tile should be rendered above player
	 */
	extern void read_tile_bcde(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin, bool is_over_player);

	/**
	 * Read A1 tile. These tiles are fluids autotiles. The tiles are animated. Can be in 2 or 4 parts
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_tile_a1(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin);

	/**
	 * Read A2 tile. These tiles are terrain 4 parts autotiles
	 * @todo handle 'is_table' flag
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 * @param is_table currently unused flag
	 */
	extern void read_tile_a2(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin, bool is_table);

	/**
	 * Read A3 tile. These tiles are buldings 4 parts autotiles
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_tile_a3(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin);

	/**
	 * Read A4 tile. These tiles are walls 4 parts autotiles
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_tile_a4(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin);

	/**
	 * Read A5 tile. These tiles are other general tiles
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_tile_a5(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin);

	/**
	 * Guess tile type and create primitives for it
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_tile_primitives(TilemapReader& reader, int16_t tile_id, int16_t flag, const glm::vec3& origin);

	/**
	 * Read shadow tile primitives. Shadow tileset are 4x4 tiles with some with blac semi-transparent quaters
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tile_id Tile ID, containing texture index, and texture offset. @ref RxTilemap::map_data
	 * @param origin 3D Coordinates of this tile
	 */
	extern void read_shadow_primitives(TilemapReader& reader, int16_t tile_id, const glm::vec3& origin);

	/**
	 * Read tileset tiles primitives from @ref RxTilemap::map_data and optional flags
	 * @param reader Tile primitives reader. @see TilemapReader
	 * @param tilemap The tilemap to read tiles
	 * @param z_offset Z layer of the tilemap. All tiles are offsetted by the 'z_offset'
	 */
	extern void read_tilemap_primitives(TilemapReader& reader, const RxTilemap* tilemap, int z_offset);
};
