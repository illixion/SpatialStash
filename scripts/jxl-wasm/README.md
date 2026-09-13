# Animated-JXL WASM decoder

Builds the WebAssembly libjxl decoder that powers on-device animated JPEG XL
playback. WebKit can't decode JXL in an `<img>`, and ImageIO exposes only the
first frame of an animation, so the app decodes the frames itself in WASM and
muxes an APNG that a plain `<img>` animates (WebKit then owns the animation
lifecycle — pause/resume offscreen — the same reason the video path uses
`<img>`).

## Pieces

- `jxl_anim.cc` — decode-only wrapper over libjxl's `JxlDecoder`. Exposes every
  frame as RGBA + its duration (ms). Single-threaded (no pthreads → no
  COOP/COEP, so it loads from a `data:`/null-origin document in WKWebView).
- `CMakeLists.txt` — adds libjxl as a subdirectory, decode-only, and links the
  wrapper into a SINGLE_FILE emscripten module (`MODULARIZE`, `EXPORT_NAME`
  `JxlAnimModule`, wasm embedded as base64).
- `build.sh` — configure + build with emcmake.

## Prerequisites

- emscripten SDK, e.g. `git clone https://github.com/emscripten-core/emsdk`
  then `./emsdk install latest && ./emsdk activate latest`. `build.sh` sources
  `~/Projects/emsdk/emsdk_env.sh` — adjust if yours lives elsewhere.
- libjxl checkout at `~/Projects/libjxl` (shallow clone with submodules), or
  pass `-DLIBJXL_DIR=/path/to/libjxl` to cmake.

## Build & install

```sh
./build.sh
cp build/jxl_decoder.js ../../Hypnos/Hypnos/Resources/JXL/jxl_decoder.js
```

The two shipped runtime files live in
`Hypnos/Hypnos/Resources/JXL/`:

- `jxl_decoder.js` — the emscripten module (build output; ~888 KB, wasm
  embedded). Loaded via a `data:` URL `<script src>` because the minified
  output contains `</script>` substrings that break an inline `<script>` block.
- `jxl-anim.js` — the APNG muxer + `window.RoboFrameJXL` API. Hand-written
  source; edit it there.

Consumers: `Views/Pictures/AnimatedJXLWebView.swift` (renderer) and
`Data+AnimatedJXL.swift` (codestream `have_animation` detector — ImageIO can't
tell an animated JXL apart, it reports frame count 1).
