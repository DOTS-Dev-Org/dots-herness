cmake_minimum_required(VERSION 3.21)
project(dots_vision_runtime LANGUAGES CXX)

# Keep the native backend pinned: the libmtmd API is explicitly experimental.
set(DOTS_LLAMA_CPP_COMMIT "ca3d5a3e10d53f7ea672cb9b6178faca3e2807bc" CACHE STRING "Pinned llama.cpp commit")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
    llama_cpp
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
    GIT_TAG ${DOTS_LLAMA_CPP_COMMIT}
    GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(llama_cpp)

add_library(dots_vision_runtime SHARED dots_vision_runtime.cpp)
target_compile_features(dots_vision_runtime PRIVATE cxx_std_17)
target_compile_definitions(dots_vision_runtime PRIVATE DOTS_VISION_BUILD)
target_include_directories(dots_vision_runtime PRIVATE
    ${llama_cpp_SOURCE_DIR}/include
    ${llama_cpp_SOURCE_DIR}/tools/mtmd
)
target_link_libraries(dots_vision_runtime PRIVATE mtmd)
set_target_properties(dots_vision_runtime PROPERTIES
    OUTPUT_NAME dots_vision_runtime
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

if(APPLE)
    set_target_properties(dots_vision_runtime PROPERTIES INSTALL_RPATH "@loader_path")
elseif(UNIX)
    set_target_properties(dots_vision_runtime PROPERTIES INSTALL_RPATH "$ORIGIN")
endif()

install(TARGETS dots_vision_runtime LIBRARY RUNTIME ARCHIVE DESTINATION .)
