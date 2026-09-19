cmake_minimum_required(VERSION 3.22.1)
project(herness_git C CXX)

add_library(herness_git SHARED
    MobileGitClientJni.cpp
    ../../../../../native/MobileGitClient.c
)

target_include_directories(herness_git PRIVATE ../../../../../native)

# Pass -DHERNESS_LIBGIT2_ROOT=/path/to/libgit2 when packaging a build that
# supplies libgit2. The default APK remains buildable but reports the explicit
# libgit2_not_linked result instead of pretending Git succeeded.
if (HERNESS_LIBGIT2_ROOT)
    target_include_directories(herness_git PRIVATE "${HERNESS_LIBGIT2_ROOT}/include")
    find_library(HERNESS_LIBGIT2_LIBRARY NAMES git2 libgit2 PATHS "${HERNESS_LIBGIT2_ROOT}/lib" NO_DEFAULT_PATH)
    if (NOT HERNESS_LIBGIT2_LIBRARY)
        message(FATAL_ERROR "HERNESS_LIBGIT2_ROOT was set but libgit2 was not found")
    endif()
    target_compile_definitions(herness_git PRIVATE HERNESS_HAS_LIBGIT2=1)
    target_link_libraries(herness_git "${HERNESS_LIBGIT2_LIBRARY}")
endif()
