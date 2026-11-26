#pragma once
#include "../../RMClasses.hpp"
#include <array>
namespace rm_modloader::renderer {
struct TileSpriteSnapshot : RxTilemapSprite { int columns, rows; };
extern std::array<void*,12> tile_vtable, plane_vtable;
// Bind RGSS301 immutable helpers and snapshot-only virtual draw methods.
void initialize_snapshot_replay();
}
