// IPC stream writers — наша сторона общения с gameoverlayui64.exe.
//
// Архитектура: Steam использует именованные shared memory регионы (named
// FileMapping'и + Event'ы) как ring buffer'ы. Writer пишет, signal'ит
// "_written" event, reader читает.

#pragma once

#include <cstdint>
#include <Windows.h>

// InputStream opcode 0 = enable overlay, opcode 1 = disable.
// Подтверждено логами gameoverlayui:
//   opcode 0 → "Overlay enable requested by game"
//   opcode 1 → "Overlay disable requested by game"
bool SendOverlayActivate(uint32_t op_open_or_close);
