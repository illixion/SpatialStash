// Minimal decode-only libjxl wrapper for the browser/WKWebView.
//
// Decodes a full JXL buffer (still or animated) held in WASM memory and
// exposes every frame as 8-bit RGBA plus its display duration in
// milliseconds. Single-threaded on purpose: no JxlThreadParallelRunner, so
// the build needs no pthreads and no COOP/COEP headers — which WKWebView
// cannot satisfy for app-bundle content loaded off a custom scheme.
//
// The whole compressed file is fed at once (JxlDecoderCloseInput), so the
// decode never returns JXL_DEC_NEED_MORE_INPUT; the caller downloads the
// bytes before decoding.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <emscripten/emscripten.h>

namespace {

struct Frame {
  uint8_t* rgba;      // xsize*ysize*4, owned
  uint32_t delay_ms;  // 0 for a still image
};

uint32_t g_w = 0;
uint32_t g_h = 0;
uint32_t g_n = 0;      // committed frame count
uint32_t g_loops = 0;  // 0 == loop forever
Frame* g_frames = nullptr;
size_t g_cap = 0;

void free_all() {
  if (g_frames) {
    for (uint32_t i = 0; i < g_n; i++) free(g_frames[i].rgba);
    free(g_frames);
    g_frames = nullptr;
  }
  g_n = 0;
  g_cap = 0;
  g_w = 0;
  g_h = 0;
  g_loops = 0;
}

}  // namespace

extern "C" {

// Decodes `data`/`size` into the module-global frame list. Returns 0 on
// success, negative on failure. The pointer must reference WASM heap memory
// (allocate with _malloc from JS and copy the bytes in first).
EMSCRIPTEN_KEEPALIVE
int jxl_decode(const uint8_t* data, size_t size) {
  free_all();

  JxlDecoder* dec = JxlDecoderCreate(nullptr);
  if (!dec) return -1;

  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME |
                                         JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
    JxlDecoderDestroy(dec);
    return -2;
  }

  JxlDecoderSetInput(dec, data, size);
  JxlDecoderCloseInput(dec);

  const JxlPixelFormat fmt = {4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  JxlBasicInfo info;
  memset(&info, 0, sizeof(info));

  bool have_anim = false;
  double tps_num = 1.0, tps_den = 1.0;
  uint32_t pending_delay = 0;

  for (;;) {
    JxlDecoderStatus st = JxlDecoderProcessInput(dec);
    if (st == JXL_DEC_ERROR || st == JXL_DEC_NEED_MORE_INPUT) {
      free_all();
      JxlDecoderDestroy(dec);
      return st == JXL_DEC_ERROR ? -3 : -4;
    }
    if (st == JXL_DEC_SUCCESS) break;

    if (st == JXL_DEC_BASIC_INFO) {
      if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
        free_all();
        JxlDecoderDestroy(dec);
        return -5;
      }
      g_w = info.xsize;
      g_h = info.ysize;
      have_anim = info.have_animation != 0;
      if (have_anim) {
        tps_num = info.animation.tps_numerator;
        tps_den = info.animation.tps_denominator;
        g_loops = info.animation.num_loops;
      }
    } else if (st == JXL_DEC_FRAME) {
      JxlFrameHeader fh;
      memset(&fh, 0, sizeof(fh));
      JxlDecoderGetFrameHeader(dec, &fh);
      if (have_anim && tps_num > 0.0) {
        pending_delay =
            (uint32_t)((double)fh.duration * 1000.0 * tps_den / tps_num + 0.5);
      } else {
        pending_delay = 0;
      }
    } else if (st == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      size_t need = 0;
      if (JxlDecoderImageOutBufferSize(dec, &fmt, &need) != JXL_DEC_SUCCESS) {
        free_all();
        JxlDecoderDestroy(dec);
        return -6;
      }
      uint8_t* buf = (uint8_t*)malloc(need);
      if (!buf) {
        free_all();
        JxlDecoderDestroy(dec);
        return -7;
      }
      if (g_n >= g_cap) {
        g_cap = g_cap ? g_cap * 2 : 8;
        g_frames = (Frame*)realloc(g_frames, g_cap * sizeof(Frame));
      }
      // Stage at [g_n]; committed by the matching JXL_DEC_FULL_IMAGE.
      g_frames[g_n].rgba = buf;
      g_frames[g_n].delay_ms = pending_delay;
      if (JxlDecoderSetImageOutBuffer(dec, &fmt, buf, need) != JXL_DEC_SUCCESS) {
        free(buf);
        free_all();
        JxlDecoderDestroy(dec);
        return -8;
      }
    } else if (st == JXL_DEC_FULL_IMAGE) {
      g_n++;
    }
    // Any other event: keep processing.
  }

  JxlDecoderDestroy(dec);
  return g_n > 0 ? 0 : -9;
}

EMSCRIPTEN_KEEPALIVE uint32_t jxl_width() { return g_w; }
EMSCRIPTEN_KEEPALIVE uint32_t jxl_height() { return g_h; }
EMSCRIPTEN_KEEPALIVE uint32_t jxl_frame_count() { return g_n; }
EMSCRIPTEN_KEEPALIVE uint32_t jxl_loops() { return g_loops; }

EMSCRIPTEN_KEEPALIVE uint8_t* jxl_frame_rgba(uint32_t i) {
  return i < g_n ? g_frames[i].rgba : nullptr;
}

EMSCRIPTEN_KEEPALIVE uint32_t jxl_frame_delay(uint32_t i) {
  return i < g_n ? g_frames[i].delay_ms : 0;
}

EMSCRIPTEN_KEEPALIVE void jxl_free() { free_all(); }

}  // extern "C"
