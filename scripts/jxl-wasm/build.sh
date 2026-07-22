#!/usr/bin/env bash
# Build the decode-only animated-JXL WASM module.
set -euo pipefail
cd "$(dirname "$0")"

source ~/Projects/emsdk/emsdk_env.sh >/dev/null 2>&1

BUILD_DIR="build"
emcmake cmake -S . -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --target jxl_decoder -j"$(sysctl -n hw.ncpu)"

echo "=== artifact ==="
ls -la "$BUILD_DIR/jxl_decoder.js"
