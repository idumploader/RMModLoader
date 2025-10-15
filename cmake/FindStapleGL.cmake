#add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/staplegl)

set(GLAD_INCLUDE_DIRS
	${CMAKE_CURRENT_SOURCE_DIR}/staplegl/external/glad/include/glad
	${CMAKE_CURRENT_SOURCE_DIR}/staplegl/external/glad/include/
)
set(GLAD_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/staplegl/external/glad/src/glad.c)
set(GLAD_HEADERS
    ${CMAKE_CURRENT_SOURCE_DIR}/staplegl/external/glad/include/glad/glad.h
    ${CMAKE_CURRENT_SOURCE_DIR}/staplegl/external/glad/include/KHR/khrplatform.h
)

add_library(glad ${GLAD_SOURCE} ${GLAD_HEADERS})

target_include_directories(glad PRIVATE ${GLAD_INCLUDE_DIRS})

set(STAPLEGL_LIBRARIES glad)
set(STAPLEGL_INCLUDE_DIRS
	${CMAKE_CURRENT_SOURCE_DIR}/staplegl/include
	${GLAD_INCLUDE_DIRS}
)
set(STAPLEGL_FOUND ON)

#message(STATUS "Found StapleGL libraries: ${STAPLEGL_LIBRARIES}")
message(STATUS "Found StapleGL includes: ${STAPLEGL_INCLUDE_DIRS}")