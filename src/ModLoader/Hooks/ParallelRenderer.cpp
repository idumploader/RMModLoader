#include "ParallelRenderer.hpp"
#include "Renderer/RendererService.hpp"

namespace rm_modloader {
void apply_parallel_renderer() { renderer::service::install(); }
}
