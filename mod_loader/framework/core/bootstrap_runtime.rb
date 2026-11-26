# Runtime diagnostics and renderer facades preserve their native script order.
ModLoader::Framework.load('diagnostics/crash_log.rb')
ModLoader::Framework.load('diagnostics/native_profiler.rb')
ModLoader::Framework.load('renderer/parallel_renderer.rb')
ModLoader::Framework.load('renderer/last_frame_snapshot.rb')
ModLoader::Framework.load('renderer/menu_rendering.rb')
