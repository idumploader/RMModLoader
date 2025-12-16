cmake_minimum_required (VERSION 3.8)

if (CMAKE_TOOLCHAIN_FILE MATCHES "vcpkg.cmake")
	message(STATUS "Using vcpkg: ${CMAKE_TOOLCHAIN_FILE}")
	include(${CMAKE_TOOLCHAIN_FILE})
endif()

project(rmforge LANGUAGES CXX C VERSION 2.6)

include(CMakePackageConfigHelpers)

# -- find packages
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")

find_package(StapleGL REQUIRED)
find_package(GLFW3 REQUIRED)
find_package(glm REQUIRED)
find_package(nlohmann_json REQUIRED)
find_package(minhook REQUIRED)

# -- mkxp-z
#set(MKXPZ_ROOT "mkxp-z")

#file(GLOB_RECURSE MKXPZ_HEADER_FILES "${MKXPZ_ROOT}/src/*.hpp")
#file(GLOB_RECURSE MKXPZ_SOURCE_FILES "${MKXPZ_ROOT}/src/*.cpp")

#set(MKXPZ_SOURCE_FILES
#	"${MKXPZ_ROOT}/src/etc/table.cpp"
#	"${MKXPZ_ROOT}/src/display/gl/tileatlasvx.cpp"
#	"${MKXPZ_ROOT}/src/display/autotilesvx.cpp"
#)

#add_library(mkxp-z ${MKXPZ_HEADER_FILES} ${MKXPZ_SOURCE_FILES})

#target_link_libraries(mkxp-z $<BUILD_INTERFACE:glad>)

#target_include_directories(mkxp-z PRIVATE
#	${STAPLEGL_INCLUDE_DIRS}
#	${MKXPZ_ROOT}/src/util
#)

# -- ModLoader

add_library(ModLoader SHARED
	"src/ModLoader/DllMain.cpp"
	"src/ModLoader/Hooks/HRFixHooks.cpp"
	"src/ModLoader/ModLoader.cpp"
	"src/ModLoader/ModLoaderConfig.cpp"
	"src/ModLoader/RMGlobal.cpp"
	"src/ModLoader/Hooks/FastRenderHooks.cpp"
	"src/ModLoader/TilemapReader.cpp"
	"src/ModLoader/Hooks/ControlsChangeHooks.cpp"
	"src/ModLoader/Hooks/IntegratedHooks.cpp"
	"src/ModLoader/Hooks/SteamSupportHooks.cpp"
	"src/ModLoader/GLFWMisc.cpp"
)

target_compile_definitions(ModLoader PUBLIC
	-DRM_MODLOADER_VERSION_MAJOR=${PROJECT_VERSION_MAJOR}
	-DRM_MODLOADER_VERSION_MINOR=${PROJECT_VERSION_MINOR}
)
#target_precompile_headers(ModLoader PRIVATE "src/pch.h")

target_link_libraries(ModLoader PRIVATE
	$<BUILD_INTERFACE:
		${STAPLEGL_LIBRARIES}
		glfw
		glm::glm
		nlohmann_json
		minhook::minhook
#		mkxp-z
	>
)

target_include_directories(ModLoader PRIVATE
	${STAPLEGL_INCLUDE_DIRS}
#	${MKXPZ_ROOT}/src
#	${MKXPZ_ROOT}/src/util
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