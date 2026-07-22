/*
 Spatial Stash - Animated JXL Web View

 Renders an animated JPEG XL by decoding it in WebAssembly (a decode-only
 build of libjxl) and muxing the frames into an APNG that a plain `<img>`
 animates. WebKit then owns the animation loop and pauses it when the window
 is offscreen — the same lifecycle behaviour the video-in-`<img>` path relies
 on, and the reason this goes through an image element rather than a canvas.

 ImageIO can't be used: it decodes JPEG XL but exposes only the first frame of
 an animation. The bundled `jxl_decoder.js` (SINGLE_FILE emscripten build) and
 `jxl-anim.js` (APNG muxer) do the work. They are loaded via `data:` URL
 `<script src>` rather than inline `<script>` blocks: the minified emscripten
 output contains `</script>` substrings that terminate an inline block early
 (the browser then renders the rest of the decoder as page text). base64 in a
 src attribute can't break out of the tag, so the page stays self-contained and
 needs no file-URL read access.
*/

import SwiftUI
import WebKit
import os

struct AnimatedJXLWebView: UIViewRepresentable {
    /// Raw JPEG XL bytes to decode and animate.
    let imageData: Data?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let data = imageData else { return }
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        let digest = hasher.finalize()
        guard context.coordinator.loadedDigest != digest else { return }
        context.coordinator.loadedDigest = digest

        webView.loadHTMLString(Self.html(for: data), baseURL: nil)
    }

    class Coordinator { var loadedDigest: Int? }

    // Read the decoder + muxer once as base64 (for data: URL <script src>).
    // Caching avoids re-reading the 888 KB decoder from the bundle each slide.
    private static let decoderB64 = loadResourceBase64("jxl_decoder")
    private static let animB64 = loadResourceBase64("jxl-anim")

    private static func loadResourceBase64(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let data = try? Data(contentsOf: url) else {
            AppLogger.remoteViewer.error("AnimatedJXLWebView: missing bundled resource \(name, privacy: .public).js")
            return ""
        }
        return data.base64EncodedString()
    }

    private static func html(for data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
        .wrap { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: transparent; }
        #media { display: block; width: 100%; height: 100%; object-fit: contain; background: transparent; }
        </style>
        </head>
        <body>
        <div class="wrap"><img id="media" alt="animated jxl" draggable="false"></div>
        <script src="data:text/javascript;base64,\(decoderB64)"></script>
        <script src="data:text/javascript;base64,\(animB64)"></script>
        <script>
        (async function () {
          try {
            const b = "\(base64)";
            const bin = atob(b), n = bin.length, u = new Uint8Array(n);
            for (let i = 0; i < n; i++) u[i] = bin.charCodeAt(i);
            const url = await window.RoboFrameJXL.decodeToObjectURL(u.buffer);
            document.getElementById('media').src = url;
          } catch (e) {
            console.error('JXL render failed:', e);
          }
        })();
        </script>
        </body>
        </html>
        """
    }
}
