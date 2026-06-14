cmake_minimum_required (VERSION 3.8)

# Honor MSVC_RUNTIME_LIBRARY (static /MT) instead of baking the flag into CMAKE_*_FLAGS.
# Must be set before project() so the abstraction is active for the toolchain probe.
if (POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()

if (CMAKE_TOOLCHAIN_FILE MATCHES "vcpkg.cmake")
  message(STATUS "Using vcpkg: ${CMAKE_TOOLCHAIN_FILE}")
  include(${CMAKE_TOOLCHAIN_FILE})
endif()

project(rmforge LANGUAGES CXX C VERSION 3.0)

include(CMakePackageConfigHelpers)

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

target_include_directories(ModLoader PRIVATE
  ${STAPLEGL_INCLUDE_DIRS}
#  ${MKXPZ_ROOT}/src
#  ${MKXPZ_ROOT}/src/util
)

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
