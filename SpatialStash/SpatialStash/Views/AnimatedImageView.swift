/*
 Spatial Stash - Animated Image View

 WKWebView-based wrapper that displays animated GIFs using the browser's
 native GIF rendering for reliable playback without cropping issues.
 */

import SwiftUI
import WebKit

/// A SwiftUI wrapper for WKWebView that displays animated GIFs
struct AnimatedImageView: UIViewRepresentable {
    let imageData: Data
    let contentMode: UIView.ContentMode

    init(data: Data, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.imageData = data
        self.contentMode = contentMode
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let base64String = imageData.base64EncodedString()
        let objectFit = contentMode == .scaleAspectFit ? "contain" : "cover"

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
                    max-width: 100%;
                    max-height: 100%;
                    width: auto;
                    height: auto;
                    object-fit: \(objectFit);
                }
            </style>
        </head>
        <body>
            <div class="image-container">
                <img src="data:image/gif;base64,\(base64String)" alt="Animated GIF">
            </div>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
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
