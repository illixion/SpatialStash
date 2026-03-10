/*
 Spatial Stash - Animated Image View

 WKWebView-based wrapper that displays animated images. Prefers HEVC .mp4
 playback via <img src="file.mp4"> for reliable multi-window support on
 visionOS, falling back to base64 GIF data URI when no HEVC file is available.
 */

import SwiftUI
import WebKit

/// A SwiftUI wrapper for WKWebView that displays animated GIFs or HEVC animations
struct AnimatedImageView: UIViewRepresentable {
    let imageData: Data
    let hevcFileURL: URL?
    let contentMode: UIView.ContentMode

    init(data: Data, hevcFileURL: URL? = nil, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.imageData = data
        self.hevcFileURL = hevcFileURL
        self.contentMode = contentMode
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        // Disable user interaction so taps pass through to SwiftUI for UI toggle
        webView.isUserInteractionEnabled = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let objectFit = contentMode == .scaleAspectFit ? "contain" : "cover"

        let imgSrc: String
        if let hevcURL = hevcFileURL {
            imgSrc = hevcURL.lastPathComponent
        } else {
            let base64String = imageData.base64EncodedString()
            imgSrc = "data:image/gif;base64,\(base64String)"
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    background: transparent;
                    overflow: hidden;
                }
                .image-container {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: transparent;
                }
                img {
                    width: 100%;
                    height: 100%;
                    object-fit: \(objectFit);
                    border: none;
                    outline: none;
                }
            </style>
        </head>
        <body>
            <div class="image-container">
                <img src="\(imgSrc)" alt="Animated GIF">
            </div>
        </body>
        </html>
        """

        if let hevcURL = hevcFileURL {
            // Write a temporary HTML file next to the .mp4 so loadFileURL grants
            // read access to the cache directory and the <img src> resolves correctly.
            let htmlURL = hevcURL.deletingPathExtension().appendingPathExtension("html")
            try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
            let cacheDir = hevcURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: cacheDir)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

/// Helper to detect if image data is an animated GIF
extension Data {
    var isAnimatedGIF: Bool {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 1
    }
}
