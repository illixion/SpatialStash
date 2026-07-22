cmake_minimum_required(VERSION 3.16)
project(jxl_anim_wasm CXX)

# Path to the libjxl checkout (sibling clone by default).
if(NOT DEFINED LIBJXL_DIR)
  set(LIBJXL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../libjxl")
endif()

# Decode-only, no tools/tests/plugins — smallest possible WASM.
set(JPEGXL_ENABLE_TOOLS OFF CACHE BOOL "")
set(JPEGXL_ENABLE_BENCHMARK OFF CACHE BOOL "")
set(JPEGXL_ENABLE_EXAMPLES OFF CACHE BOOL "")
set(JPEGXL_ENABLE_MANPAGES OFF CACHE BOOL "")
set(JPEGXL_ENABLE_JNI OFF CACHE BOOL "")
set(JPEGXL_ENABLE_SJPEG OFF CACHE BOOL "")
set(JPEGXL_ENABLE_OPENEXR OFF CACHE BOOL "")
set(JPEGXL_ENABLE_TRANSCODE_JPEG OFF CACHE BOOL "")
set(JPEGXL_ENABLE_PLUGINS OFF CACHE BOOL "")
set(JPEGXL_ENABLE_DEVTOOLS OFF CACHE BOOL "")
set(JPEGXL_ENABLE_DOXYGEN OFF CACHE BOOL "")
set(JPEGXL_ENABLE_MANPAGES OFF CACHE BOOL "")
set(JPEGXL_ENABLE_VIEWERS OFF CACHE BOOL "")
set(JPEGXL_ENABLE_FUZZERS OFF CACHE BOOL "")
set(JPEGXL_ENABLE_COVERAGE OFF CACHE BOOL "")
set(BUILD_TESTING OFF CACHE BOOL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
set(SJPEG_ENABLE_SIMD OFF CACHE BOOL "")

# Cross-compile shims libjxl's CI passes for WASM.
set(CMAKE_CROSSCOMPILING 1)
set(HAVE_STD_REGEX 0)
set(HAVE_POSIX_REGEX 0)
set(HAVE_GNU_POSIX_REGEX 0)
set(HAVE_STEADY_CLOCK 0)
set(HAVE_THREAD_SAFETY_ATTRIBUTES 0)

add_subdirectory(${LIBJXL_DIR} libjxl EXCLUDE_FROM_ALL)

add_executable(jxl_decoder jxl_anim.cc)
target_link_libraries(jxl_decoder PRIVATE jxl_dec)
target_include_directories(jxl_decoder PRIVATE
  "${LIBJXL_DIR}/lib/include"
  "${CMAKE_CURRENT_BINARY_DIR}/libjxl/lib/include")

# Single-threaded decode → no pthreads / no COOP-COEP, so the module loads
# fine from an app-bundle custom scheme inside WKWebView. SINGLE_FILE embeds
# the wasm as base64 in the .js so there is exactly one artifact to bundle and
# no separate .wasm fetch to MIME-configure.
set_target_properties(jxl_decoder PROPERTIES
  OUTPUT_NAME "jxl_decoder"
  SUFFIX ".js"
  LINK_FLAGS "\
-O3 \
-sMODULARIZE=1 \
-sEXPORT_NAME=JxlAnimModule \
-sALLOW_MEMORY_GROWTH=1 \
-sSINGLE_FILE=1 \
-sENVIRONMENT=web \
-sDISABLE_EXCEPTION_CATCHING=1 \
-sEXPORTED_RUNTIME_METHODS=['HEAPU8','cwrap','ccall'] \
-sEXPORTED_FUNCTIONS=['_jxl_decode','_jxl_width','_jxl_height','_jxl_frame_count','_jxl_frame_rgba','_jxl_frame_delay','_jxl_loops','_jxl_free','_malloc','_free'] \
")
