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
    var showControls: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        let coordinator = context.coordinator

        // Only reload the page when the video URL changes
        if coordinator.loadedURL != videoURL {
            coordinator.loadedURL = videoURL
            if videoURL.isFileURL {
                loadLocalVideo(webView: webView, coordinator: coordinator, fileURL: videoURL)
            } else {
                let html = generateVideoHTML(for: videoURL, apiKey: apiKey)
                webView.loadHTMLString(html, baseURL: videoURL)
            }
        }

        // Toggle controls via JS without reloading
        if coordinator.lastShowControls != showControls {
            coordinator.lastShowControls = showControls
            let js = "document.getElementById('player').controls = \(showControls);"
            webView.evaluateJavaScript(js)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanupHTMLFile()
    }

    /// Load a local video by writing a temporary HTML file into the video's directory
    /// and using loadFileURL to grant WKWebView read access to that directory.
    private func loadLocalVideo(webView: WKWebView, coordinator: Coordinator, fileURL: URL) {
        // Use relative filename so WKWebView resolves it against the HTML file's directory
        let relativeSrc = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? fileURL.lastPathComponent
        let html = generateVideoHTML(videoSrc: relativeSrc, apiKey: nil)
        let videoDir = fileURL.deletingLastPathComponent()
        let videoBaseName = fileURL.deletingPathExtension().lastPathComponent
        let htmlFile = videoDir.appendingPathComponent(".spatialstash_player_\(videoBaseName).html")
        // Clean up previous HTML file if switching videos
        coordinator.cleanupHTMLFile()
        try? html.write(to: htmlFile, atomically: true, encoding: .utf8)
        coordinator.htmlFileURL = htmlFile
        webView.loadFileURL(htmlFile, allowingReadAccessTo: videoDir)
    }

    class Coordinator {
        var htmlFileURL: URL?
        var loadedURL: URL?
        var lastShowControls: Bool?

        func cleanupHTMLFile() {
            guard let url = htmlFileURL else { return }
            try? FileManager.default.removeItem(at: url)
            htmlFileURL = nil
        }
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
        return generateVideoHTML(videoSrc: videoURLString, apiKey: apiKey)
    }

    private func generateVideoHTML(videoSrc: String, apiKey: String?) -> String {

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
                <video id="player" controls autoplay playsinline loop muted src="\(videoSrc)">
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
