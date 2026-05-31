#include "IpcStreams.hpp"

#include "Logger.hpp"

#include <cstdint>
#include <cstring>
#include <format>
#include <string>

using rm_modloader::Logger;

bool SendOverlayActivate(uint32_t op_open_or_close) {
	std::string base = std::format("GameOverlay_InputEventStream_{}", GetCurrentProcessId());
	HANDLE hMap = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, (base + "_mem-IPCWrapper").c_str());
	if (!hMap) {
		Logger::error(std::format("InputStream mapping not found (err={})\n", GetLastError()));
		return false;
	}
	BYTE* mem = (BYTE*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
	if (!mem) { CloseHandle(hMap); return false; }
	struct Hdr { volatile uint32_t rd, wr, cap; volatile LONG avail; };
	Hdr* h = (Hdr*)mem;
	BYTE* data = mem + 0x10;
	uint32_t pos = h->wr;
	memcpy(data + (pos % h->cap), &op_open_or_close, 4);
	h->wr = (pos + 4) % h->cap;
	_InterlockedExchangeAdd(&h->avail, 4);

	HANDLE hWritten = OpenEventA(EVENT_MODIFY_STATE, FALSE, (base + "_written-IPCWrapper").c_str());
	if (hWritten) { SetEvent(hWritten); CloseHandle(hWritten); }
	UnmapViewOfFile(mem);
	CloseHandle(hMap);

	Logger::info(std::format("InputStream opcode={} sent\n", op_open_or_close));
	return true;
}
