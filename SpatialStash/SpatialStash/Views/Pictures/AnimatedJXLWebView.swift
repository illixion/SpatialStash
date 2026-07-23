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
    /// A previously-decoded APNG for this media (from DiskJXLAnimationCache).
    /// When present the WASM decode is skipped entirely — the image is shown
    /// straight from the cache.
    var cachedAPNG: Data? = nil
    /// Source URL used as the cache key when saving a fresh decode.
    var sourceURL: URL? = nil

    /// JS→Swift channel the page posts the base64 APNG on after a fresh decode.
    private static let cacheMessageName = "jxlCache"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Self.cacheMessageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.sourceURL = sourceURL

        // Prefer a cached decode (instant, no WASM). Fall back to raw bytes.
        if let apng = cachedAPNG {
            let digest = Self.digest(of: apng, tag: 1)
            guard context.coordinator.loadedDigest != digest else { return }
            context.coordinator.loadedDigest = digest
            webView.loadHTMLString(Self.cachedHTML(for: apng), baseURL: nil)
            return
        }

        guard let data = imageData else { return }
        let digest = Self.digest(of: data, tag: 0)
        guard context.coordinator.loadedDigest != digest else { return }
        context.coordinator.loadedDigest = digest
        webView.loadHTMLString(Self.decodeHTML(for: data), baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: cacheMessageName)
    }

    private static func digest(of data: Data, tag: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(tag)
        hasher.combine(data.count)
        hasher.combine(data.prefix(64))
        return hasher.finalize()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedDigest: Int?
        var sourceURL: URL?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == AnimatedJXLWebView.cacheMessageName,
                  let base64 = message.body as? String,
                  let data = Data(base64Encoded: base64),
                  let url = sourceURL else { return }
            Task { await DiskJXLAnimationCache.shared.saveData(data, for: url) }
        }
    }

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

    // Shared page chrome: transparent full-bleed image, hidden until ready so
    // the alt-text placeholder never paints, plus a centered loading spinner.
    private static let headAndBody = """
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
    .wrap { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: transparent; }
    #media { display: block; width: 100%; height: 100%; object-fit: contain; background: transparent; opacity: 0; transition: opacity 0.25s ease; }
    #media.ready { opacity: 1; }
    .spinner {
      position: absolute; top: 50%; left: 50%;
      width: 44px; height: 44px; margin: -22px 0 0 -22px;
      border: 4px solid rgba(255,255,255,0.25);
      border-top-color: rgba(255,255,255,0.9);
      border-radius: 50%;
      animation: spin 0.9s linear infinite;
    }
    .spinner.hidden { display: none; }
    @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    """

    /// Page for a fresh decode: runs the WASM decoder + APNG muxer, displays the
    /// result, and posts the encoded bytes back to Swift so the next open is
    /// served from the cache without decoding.
    private static func decodeHTML(for data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        <!doctype html><html><head>\(headAndBody)</head>
        <body>
        <div class="wrap"><img id="media" alt="" draggable="false"><div id="spinner" class="spinner"></div></div>
        <script src="data:text/javascript;base64,\(decoderB64)"></script>
        <script src="data:text/javascript;base64,\(animB64)"></script>
        <script>
        (async function () {
          const media = document.getElementById('media');
          const spinner = document.getElementById('spinner');
          const reveal = () => { spinner.classList.add('hidden'); media.classList.add('ready'); };
          try {
            const b = "\(base64)";
            const bin = atob(b), n = bin.length, u = new Uint8Array(n);
            for (let i = 0; i < n; i++) u[i] = bin.charCodeAt(i);
            const blob = await window.RoboFrameJXL.decodeToBlob(u.buffer);
            const reader = new FileReader();
            reader.onload = () => {
              const dataURL = reader.result;
              media.onload = reveal;
              media.onerror = reveal;
              media.src = dataURL;
              // Hand the decoded APNG to Swift for caching (strip the data: prefix).
              try {
                const comma = dataURL.indexOf(',');
                window.webkit.messageHandlers.jxlCache.postMessage(dataURL.slice(comma + 1));
              } catch (e) {}
            };
            reader.onerror = reveal;
            reader.readAsDataURL(blob);
          } catch (e) {
            console.error('JXL render failed:', e);
            reveal();
          }
        })();
        </script>
        </body></html>
        """
    }

    /// Page for a cached decode: just the muxed APNG, no decoder/muxer scripts.
    private static func cachedHTML(for apng: Data) -> String {
        let base64 = apng.base64EncodedString()
        return """
        <!doctype html><html><head>\(headAndBody)</head>
        <body>
        <div class="wrap"><img id="media" alt="" draggable="false"><div id="spinner" class="spinner"></div></div>
        <script>
        (function () {
          const media = document.getElementById('media');
          const spinner = document.getElementById('spinner');
          const reveal = () => { spinner.classList.add('hidden'); media.classList.add('ready'); };
          media.onload = reveal;
          media.onerror = reveal;
          media.src = "data:image/png;base64,\(base64)";
        })();
        </script>
        </body></html>
        """
    }
}
