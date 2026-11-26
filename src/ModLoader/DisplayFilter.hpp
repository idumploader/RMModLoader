#pragma once
#include <windows.h>
#include <ddraw.h>

namespace rm_modloader {
// Preserve the caller's DC state. Anchor the halftone brush in destination
// coordinates so separate engine strips use the same origin.
inline bool stretch_display(HDC target, const RECT& output, HDC source,
                            const RECT& input, DWORD operation, bool smooth) {
    const int saved = SaveDC(target);
    if (!saved) return false;
    bool ok = SetStretchBltMode(target, smooth ? HALFTONE : COLORONCOLOR) != 0;
    if (smooth) ok = ok && SetBrushOrgEx(target, 0, 0, nullptr);
    if (ok) ok = StretchBlt(target, output.left, output.top,
        output.right-output.left, output.bottom-output.top, source,
        input.left, input.top, input.right-input.left, input.bottom-input.top,
        operation) != FALSE;
    const bool restored = RestoreDC(target, saved) != FALSE;
    return ok && restored;
}

inline HRESULT stretch_display_surface(IDirectDrawSurface* target, const RECT& output,
                                       IDirectDrawSurface* source, const RECT* source_rect,
                                       bool smooth) {
    RECT input;
    if (source_rect) input = *source_rect;
    else {
        DDSURFACEDESC desc = {}; desc.dwSize = sizeof(desc);
        const HRESULT result = source->GetSurfaceDesc(&desc);
        if (FAILED(result)) return result;
        input = {0, 0, LONG(desc.dwWidth), LONG(desc.dwHeight)};
    }
    HDC from = nullptr, to = nullptr;
    HRESULT result = source->GetDC(&from);
    if (FAILED(result)) return result;
    result = target->GetDC(&to);
    if (FAILED(result)) { source->ReleaseDC(from); return result; }
    const bool ok = stretch_display(to, output, from, input, SRCCOPY, smooth);
    const HRESULT to_result = target->ReleaseDC(to);
    const HRESULT from_result = source->ReleaseDC(from);
    if (FAILED(to_result)) return to_result;
    if (FAILED(from_result)) return from_result;
    return ok ? DD_OK : DDERR_GENERIC;
}
}
