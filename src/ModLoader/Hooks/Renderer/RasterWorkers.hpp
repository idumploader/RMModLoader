#pragma once
#include "../../RMClasses.hpp"
namespace rm_modloader::renderer {
void install_raster_workers();
void ensure_raster_workers();
void set_raster_worker_count(int);
void reset_raster_workers();
void set_parallel_stretch(bool);
int draw_viewport_stretch(Surface*,RECT*,Surface*,RECT*,void*);
int raster_thread_count();
bool run_shared_raster_bands(void (*)(void*,int) noexcept,void*);
}
