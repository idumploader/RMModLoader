#include "ModLoader.hpp"

static int startup_dll() {
    return rm_modloader::detail::ModLoaderBooter::init();
}

static int clean_dll() {
    return rm_modloader::detail::ModLoaderBooter::deinit();
}

BOOL WINAPI DllMain(HINSTANCE dll_instance, DWORD reason, LPVOID) {
    int error = 0;

    switch (reason) {
    case DLL_PROCESS_ATTACH:
        error = startup_dll();
        break;
    case DLL_PROCESS_DETACH:
        error = clean_dll();
        break;
    }

    return error == 0;
}