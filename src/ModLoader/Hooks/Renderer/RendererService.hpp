#pragma once
#include "../../RMClasses.hpp"
#include <string>
namespace rm_modloader::renderer::service {
// Native operation boundary. Calls are synchronous on the game thread; queued
// jobs contain only owned captured data. Ruby adapters decode before calling.
void install();
void begin_api_operation(bool allow_frame_mode=false);
void set_api_error(const char*) noexcept;
Sprite* screen_root();
void capture(Sprite*,bool detached);
void draw_snapshot(Surface*);
void reference(Sprite*,bool detached,Surface*);
void clear();
void start(Surface*,int repeats);
void submit(Sprite*,bool detached,Surface*,int repeats);
void collect(Surface*);
void benchmark(Sprite*,bool detached,Surface*,int count,bool use_snapshot);
void set_mode(int);
int current_mode();
void set_workers(int);
int workers();
void set_direct_output(bool);
bool direct_output();
void set_parallel_stretch(bool);
bool parallel_stretch();
void set_memory_limit(int);
unsigned memory_limit();
void set_optimization(int);
void invalidate(Surface*);
bool pixels_equal(Surface*,Surface*);
std::string status();
std::string frame_status();
const std::string& frame_error();
int health();
void set_validation(bool);
void barrier();
void enable_last_frame(bool);
bool last_frame_ready();
void copy_last_frame(Surface*);
std::string last_frame_status();
void notify_bitmap_changed(Surface*);
}
