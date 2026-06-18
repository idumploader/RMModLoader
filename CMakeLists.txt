cmake_minimum_required (VERSION 3.8)

# Honor CMAKE_MSVC_RUNTIME_LIBRARY (CMP0091). Without NEW it is ignored and the
# runtime is baked into the per-config flags the old way.
if (POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()

if (CMAKE_TOOLCHAIN_FILE MATCHES "vcpkg.cmake")
  message(STATUS "Using vcpkg: ${CMAKE_TOOLCHAIN_FILE}")
  include(${CMAKE_TOOLCHAIN_FILE})
endif()

project(rmforge LANGUAGES CXX C VERSION 3.0)

include(CMakePackageConfigHelpers)

# Pin the dynamic *release* CRT/STL for every config. The DLL is injected into
# the game, a release process that uses msvcp140.dll. A Debug build otherwise
# defaults to /MDd (msvcp140d.dll) + _ITERATOR_DEBUG_LEVEL=2 — a different STL
# ABI and a second runtime in the process, and it also drags in the debug
# variants of dependency DLLs (e.g. minhook.x32d.dll) that have to be shipped
# next to the game. Forcing /MD keeps a single runtime matching the host, so a
# Debug build behaves like Release (just with symbols / -Od) and needs no debug
# runtime/deps. Needs CMP0091 NEW (set above) to take effect.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

# CMP0091 injects the runtime as a separate -MD flag, but the vcpkg toolchain
# still leaves a /MDd in the per-config flag vars, so cl gets both and warns
# D9025 "overriding /MDd with /MD". Strip the stale slash-form runtime tokens
# (the abstraction's dash-form -MD is added independently and is untouched).
foreach(flag_var
    CMAKE_C_FLAGS_DEBUG   CMAKE_C_FLAGS_RELEASE   CMAKE_C_FLAGS_RELWITHDEBINFO   CMAKE_C_FLAGS_MINSIZEREL
    CMAKE_CXX_FLAGS_DEBUG CMAKE_CXX_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELWITHDEBINFO CMAKE_CXX_FLAGS_MINSIZEREL)
  string(REGEX REPLACE "/M[DT]d?" "" ${flag_var} "${${flag_var}}")
endforeach()

# -- find packages
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")

find_package(StapleGL REQUIRED)
find_package(GLFW3 REQUIRED)
find_package(glm REQUIRED)
find_package(nlohmann_json REQUIRED)
find_package(minhook REQUIRED)
find_package(httplib CONFIG REQUIRED)

# -- ModLoader

add_library(ModLoader SHARED
  "src/ModLoader/DllMain.cpp"
  "src/ModLoader/Hooks/HRFixHooks.cpp"
  "src/ModLoader/ModLoader.cpp"
  "src/ModLoader/ModLoaderConfig.cpp"
  "src/ModLoader/RMGlobal.cpp"
  "src/ModLoader/TilemapReader.cpp"
  "src/ModLoader/GLFWMisc.cpp"
  "src/ModLoader/Logger.cpp"

  "src/ModLoader/Hooks/FastRenderHooks.cpp"
  "src/ModLoader/Hooks/ControlsChangeHooks.cpp"
  "src/ModLoader/Hooks/IntegratedHooks.cpp"
  "src/ModLoader/Hooks/SteamSupportHooks.cpp"
  "src/ModLoader/Hooks/FileManagerHooks.cpp"
  "src/ModLoader/Hooks/SteamOverlayHooks.cpp"
  "src/ModLoader/Hooks/SpriteDisposeFixHooks.cpp"
  "src/ModLoader/Hooks/HttpServerHooks.cpp"
  "src/ModLoader/Hooks/FocusPauseHooks.cpp"

  "src/ModLoader/SteamOverlay/DLLResolver.cpp"
  "src/ModLoader/SteamOverlay/IPCStreams.cpp"
  "src/ModLoader/SteamOverlay/FakeRenderer.cpp"
  "src/ModLoader/SteamOverlay/GDIRender.cpp"
  "src/ModLoader/SteamOverlay/SteamOverlay.cpp"
  "src/ModLoader/SteamOverlay/SteamLoader.cpp"
)

target_compile_definitions(ModLoader PUBLIC
  -DRM_MODLOADER_VERSION_MAJOR=${PROJECT_VERSION_MAJOR}
  -DRM_MODLOADER_VERSION_MINOR=${PROJECT_VERSION_MINOR}
)

# Use the pre-17.10 std::mutex constructor layout (avoids the VS 2022 17.10 ABI
# break that crashes std::mutex when an older msvcp140 is present).
target_compile_definitions(ModLoader PRIVATE _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
target_link_options(ModLoader PRIVATE "/MAP")
#target_precompile_headers(ModLoader PRIVATE "src/pch.h")

# The vendored Steamworks SDK headers (src/ModLoader/Steam) use deprecated CRT
# calls (strncpy in matchmakingtypes.h) -> C4996. Don't patch the SDK; suppress
# the deprecation only on the TUs that pull it in.
set_source_files_properties(
  "src/ModLoader/Hooks/SteamSupportHooks.cpp"
  "src/ModLoader/SteamOverlay/SteamOverlay.cpp"
  "src/ModLoader/SteamOverlay/SteamLoader.cpp"
  "src/ModLoader/SteamOverlay/FakeRenderer.cpp"
  PROPERTIES COMPILE_DEFINITIONS _CRT_SECURE_NO_WARNINGS
)


target_link_libraries(ModLoader PRIVATE
  $<BUILD_INTERFACE:
    ${STAPLEGL_LIBRARIES}
    glfw
    glm::glm
    nlohmann_json
    minhook::minhook
    httplib::httplib
#    mkxp-z
  >
)

target_include_directories(ModLoader SYSTEM PRIVATE
  ${STAPLEGL_INCLUDE_DIRS}
#  ${MKXPZ_ROOT}/src
#  ${MKXPZ_ROOT}/src/util
)

# Treat the vendored StapleGL headers as system headers so their internal
# warnings (e.g. C4244 in utility.hpp) don't pollute our build. /external:W0
# applies a zero warning level to headers reached via /external:I (SYSTEM above).
target_compile_options(ModLoader PRIVATE /external:W0)

set_property(TARGET ModLoader PROPERTY CXX_STANDARD 20)

# -- Loader
add_executable(Loader
  "src/Loader/Loader.cpp"
  "src/Loader/Resource.rc"
)

set_property(TARGET Loader PROPERTY CXX_STANDARD 20)

configure_package_config_file(
  "rmforge-config.cmake.in"
  "rmforge-config.cmake"
INSTALL_DESTINATION
  "share/rmforge"
)

install(
FILES 
  "${CMAKE_CURRENT_BINARY_DIR}/rmforge-config.cmake"
DESTINATION 
  "share/rmforge"
)

# -- install
install(TARGETS ModLoader Loader
  EXPORT rmforge-targets
  RUNTIME DESTINATION "bin"
  ARCHIVE DESTINATION "lib"
  LIBRARY DESTINATION "lib"
)

install(
EXPORT
  rmforge-targets
NAMESPACE 
  rmforge::
DESTINATION 
  "share/rmforge"
)

install(
  DIRECTORY mod_loader DESTINATION "bin"
)
