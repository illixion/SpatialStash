/*
 Spatial Stash - Web Video Player View

 WKWebView-based video player that supports WebM and other formats
 not natively supported by AVPlayer.
 */

import SwiftUI
import WebKit

struct WebVideoPlayerView: UIViewRepresentable {
    let videoURL: URL
    let apiKey: String?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = generateVideoHTML(for: videoURL, apiKey: apiKey)
        webView.loadHTMLString(html, baseURL: videoURL)
    }

    private func generateVideoHTML(for url: URL, apiKey: String?) -> String {
        // Append API key as query parameter if present
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let apiKey = apiKey, !apiKey.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
            components.queryItems = queryItems
        }
        let videoURLString = components.url?.absoluteString ?? url.absoluteString

        return """
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
                .video-container {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: transparent;
                }
                video {
                    max-width: 100%;
                    max-height: 100%;
                    width: auto;
                    height: auto;
                    object-fit: contain;
                    background: transparent;
                }
                .error {
                    color: #ff6b6b;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    text-align: center;
                    padding: 20px;
                }
            </style>
        </head>
        <body>
            <div class="video-container">
                <video id="player" controls autoplay playsinline loop muted src="\(videoURLString)">
                    Your browser does not support video playback.
                </video>
            </div>
            <script>
                const video = document.getElementById('player');
                video.onerror = function() {
                    const container = document.querySelector('.video-container');
                    container.innerHTML = '<div class="error">Failed to load video</div>';
                };
            </script>
        </body>
        </html>
        """
    }
}
