// Animated-JXL → APNG bridge for WKWebView.
//
// Pairs with jxl_decoder.js (emscripten SINGLE_FILE build of the libjxl
// decode wrapper). Decodes a JXL buffer to RGBA frames in WASM, then muxes
// them into an APNG blob so a plain <img src> animates it — WebKit owns the
// animation loop and pauses it when the view is offscreen, which is the
// whole reason for going through an image element instead of a canvas.
//
// Exposes window.RoboFrameJXL.decodeToObjectURL(arrayBuffer) → Promise<string>.
// A still (single-frame) JXL is emitted as a plain PNG, not an APNG.

(function () {
  'use strict';

  let modulePromise = null;
  function getModule() {
    // JxlAnimModule is the MODULARIZE factory from the emscripten build.
    if (!modulePromise) modulePromise = JxlAnimModule();
    return modulePromise;
  }

  // --- PNG/APNG primitives ---------------------------------------------------

  const CRC_TABLE = (function () {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();

  function crc32(buf, start, end) {
    let c = 0xffffffff;
    for (let i = start; i < end; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }

  // Build a PNG chunk: length + type + data + CRC(type+data).
  function chunk(type, data) {
    const len = data.length;
    const out = new Uint8Array(12 + len);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, len);
    out[4] = type.charCodeAt(0);
    out[5] = type.charCodeAt(1);
    out[6] = type.charCodeAt(2);
    out[7] = type.charCodeAt(3);
    out.set(data, 8);
    dv.setUint32(8 + len, crc32(out, 4, 8 + len));
    return out;
  }

  // zlib (RFC1950) datastream, as PNG IDAT/fdAT require. CompressionStream
  // 'deflate' emits the zlib wrapper (header + adler32); 'deflate-raw' would
  // not, so it must be 'deflate' here.
  async function zlibDeflate(bytes) {
    const cs = new CompressionStream('deflate');
    const writer = cs.writable.getWriter();
    writer.write(bytes);
    writer.close();
    const reader = cs.readable.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      total += value.length;
    }
    const out = new Uint8Array(total);
    let o = 0;
    for (const c of chunks) {
      out.set(c, o);
      o += c.length;
    }
    return out;
  }

  // Prefix each RGBA scanline with filter byte 0 (None).
  function filterRGBA(rgba, w, h) {
    const stride = w * 4;
    const out = new Uint8Array((stride + 1) * h);
    for (let y = 0; y < h; y++) {
      const dst = y * (stride + 1);
      out[dst] = 0;
      out.set(rgba.subarray(y * stride, y * stride + stride), dst + 1);
    }
    return out;
  }

  function ihdrData(w, h) {
    const d = new Uint8Array(13);
    const dv = new DataView(d.buffer);
    dv.setUint32(0, w);
    dv.setUint32(4, h);
    d[8] = 8; // bit depth
    d[9] = 6; // color type RGBA
    d[10] = 0; // compression
    d[11] = 0; // filter
    d[12] = 0; // interlace
    return d;
  }

  const PNG_SIG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  async function encodePNG(frame, w, h) {
    const comp = await zlibDeflate(filterRGBA(frame.rgba, w, h));
    return new Blob([PNG_SIG, chunk('IHDR', ihdrData(w, h)), chunk('IDAT', comp), chunk('IEND', new Uint8Array(0))], {
      type: 'image/png',
    });
  }

  async function encodeAPNG(frames, w, h, loops) {
    const parts = [PNG_SIG, chunk('IHDR', ihdrData(w, h))];

    const actl = new Uint8Array(8);
    const av = new DataView(actl.buffer);
    av.setUint32(0, frames.length);
    av.setUint32(4, loops); // 0 == loop forever
    parts.push(chunk('acTL', actl));

    let seq = 0;
    for (let i = 0; i < frames.length; i++) {
      const f = frames[i];
      const fctl = new Uint8Array(26);
      const fv = new DataView(fctl.buffer);
      fv.setUint32(0, seq++);
      fv.setUint32(4, w);
      fv.setUint32(8, h);
      fv.setUint32(12, 0); // x_offset
      fv.setUint32(16, 0); // y_offset
      // delay_num / delay_den (ms). Clamp to uint16; 0-duration frames in an
      // animation get a sane default so they don't spin at native speed.
      const delay = Math.min(65535, f.delay > 0 ? f.delay : 100);
      fv.setUint16(20, delay);
      fv.setUint16(22, 1000);
      fctl[24] = 0; // dispose_op NONE
      fctl[25] = 0; // blend_op SOURCE (full-frame replace)
      parts.push(chunk('fcTL', fctl));

      const comp = await zlibDeflate(filterRGBA(f.rgba, w, h));
      if (i === 0) {
        parts.push(chunk('IDAT', comp));
      } else {
        const fd = new Uint8Array(4 + comp.length);
        new DataView(fd.buffer).setUint32(0, seq++);
        fd.set(comp, 4);
        parts.push(chunk('fdAT', fd));
      }
    }

    parts.push(chunk('IEND', new Uint8Array(0)));
    return new Blob(parts, { type: 'image/png' });
  }

  // --- Public API ------------------------------------------------------------

  async function decodeToBlob(arrayBuffer) {
    const Module = await getModule();
    const bytes = new Uint8Array(arrayBuffer);
    const ptr = Module._malloc(bytes.length);
    Module.HEAPU8.set(bytes, ptr);
    const rc = Module._jxl_decode(ptr, bytes.length);
    Module._free(ptr);
    if (rc !== 0) throw new Error('jxl_decode failed (rc=' + rc + ')');

    const w = Module._jxl_width();
    const h = Module._jxl_height();
    const n = Module._jxl_frame_count();
    const loops = Module._jxl_loops();

    const frames = [];
    for (let i = 0; i < n; i++) {
      const fptr = Module._jxl_frame_rgba(i);
      const delay = Module._jxl_frame_delay(i);
      // Copy out of the WASM heap before jxl_free reclaims it.
      frames.push({ rgba: Module.HEAPU8.slice(fptr, fptr + w * h * 4), delay });
    }
    Module._jxl_free();

    window.RoboFrameJXL.lastStats = { width: w, height: h, frames: n, loops };
    return n <= 1 ? encodePNG(frames[0], w, h) : encodeAPNG(frames, w, h, loops);
  }

  async function decodeToObjectURL(arrayBuffer) {
    const blob = await decodeToBlob(arrayBuffer);
    return URL.createObjectURL(blob);
  }

  window.RoboFrameJXL = { decodeToBlob, decodeToObjectURL };
})();
