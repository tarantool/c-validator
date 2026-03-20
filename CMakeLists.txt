cmake_minimum_required(VERSION 2.8 FATAL_ERROR)

# Forbid in-source builds to avoid .so files
# polluting the source tree and confusing LUA_CPATH.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Run cmake from a separate build directory, "
        "e.g.: cmake -B build .")
endif()

project(cv C)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()
set(CMAKE_MODULE_PATH
    "${CMAKE_CURRENT_SOURCE_DIR}" ${CMAKE_MODULE_PATH})

# Find Tarantool and Lua dependencies
set(Tarantool_FIND_REQUIRED ON)
find_package(Tarantool)
include_directories(${TARANTOOL_INCLUDE_DIRS})

# Find tarantool and luatest binaries via PATH.
find_program(TARANTOOL_BIN tarantool)
if(NOT TARANTOOL_BIN)
    message(FATAL_ERROR "tarantool not found in PATH")
endif()

find_program(LUATEST_BIN luatest)
if(NOT LUATEST_BIN)
    message(WARNING "luatest not found in PATH")
endif()

# Set CFLAGS
set(CMAKE_C_FLAGS_DEBUG
    "${CMAKE_C_FLAGS_DEBUG} -Wall -Wextra")

# Build module
add_subdirectory(cv)

enable_testing()

set(LUA_PATH
    "LUA_PATH=${PROJECT_SOURCE_DIR}/?.lua\;${PROJECT_SOURCE_DIR}/?/init.lua\;;")
set(LUA_CPATH
    "LUA_CPATH=${PROJECT_BINARY_DIR}/?.so;;")

# Register each test file as a separate ctest test.
# luatest uses filename as module name, so we pass
# the file path relative to source root.
file(GLOB LUATEST_FILES
    "${CMAKE_SOURCE_DIR}/test/*_test.lua")
foreach(TEST_FILE ${LUATEST_FILES})
    get_filename_component(TEST_NAME ${TEST_FILE} NAME_WE)
    add_test(
        NAME ${TEST_NAME}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMAND ${LUATEST_BIN} test/${TEST_NAME}.lua
    )
    set_tests_properties(${TEST_NAME} PROPERTIES
        ENVIRONMENT "${LUA_PATH};${LUA_CPATH}")
endforeach()

# Add `make check` — rebuilds then runs tests
add_custom_target(check
    DEPENDS cvalidator
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMAND ${CMAKE_CTEST_COMMAND} -V
        --test-dir ${PROJECT_BINARY_DIR})
