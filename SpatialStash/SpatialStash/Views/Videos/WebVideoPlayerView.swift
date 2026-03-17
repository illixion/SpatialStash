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
    /// Whether the window is in the user's current room. When false, auto-resume
    /// is suppressed and the video is paused to save resources.
    var isRoomActive: Bool = true
    /// Called once when the video's native dimensions become known (from the HTML video element's loadedmetadata event).
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onVideoSizeKnown = onVideoSizeKnown

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(coordinator, name: "videoDimensions")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVideoSizeKnown = onVideoSizeKnown

        // Only reload the page when the video URL changes
        if coordinator.loadedURL != videoURL {
            coordinator.loadedURL = videoURL
            coordinator.resetForNewVideo()
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

        // Pause/resume and toggle auto-resume based on room activity
        if coordinator.lastIsRoomActive != isRoomActive {
            coordinator.lastIsRoomActive = isRoomActive
            if isRoomActive {
                // Room re-entered: re-enable auto-resume and play
                let js = "window._roomActive = true; document.getElementById('player').play().catch(function() {});"
                webView.evaluateJavaScript(js)
            } else {
                // Left room: disable auto-resume and pause
                let js = "window._roomActive = false; document.getElementById('player').pause();"
                webView.evaluateJavaScript(js)
            }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "videoDimensions")
        coordinator.onVideoSizeKnown = nil
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

    class Coordinator: NSObject, WKScriptMessageHandler {
        var htmlFileURL: URL?
        var loadedURL: URL?
        var lastShowControls: Bool?
        var lastIsRoomActive: Bool?
        var onVideoSizeKnown: ((CGSize) -> Void)?
        /// Prevents firing the callback more than once per video load
        private var didReportSize: Bool = false

        func cleanupHTMLFile() {
            guard let url = htmlFileURL else { return }
            try? FileManager.default.removeItem(at: url)
            htmlFileURL = nil
        }

        func resetForNewVideo() {
            didReportSize = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "videoDimensions",
                  let body = message.body as? [String: Any],
                  let width = body["width"] as? Double,
                  let height = body["height"] as? Double,
                  width > 0, height > 0,
                  !didReportSize else { return }
            didReportSize = true
            onVideoSizeKnown?(CGSize(width: width, height: height))
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
                const originalSrc = video.src;
                let retryCount = 0;
                const maxRetries = 5;
                const baseDelay = 3000; // 3 seconds initial delay

                // Room activity flag — set by Swift via evaluateJavaScript.
                // When false, auto-resume and error recovery are suppressed.
                window._roomActive = true;

                // Reload the video source after an error with exponential backoff
                function reloadVideo() {
                    if (!window._roomActive) return;
                    if (retryCount >= maxRetries) return;
                    retryCount++;
                    const delay = baseDelay * Math.pow(2, retryCount - 1);
                    setTimeout(function() {
                        if (!window._roomActive) return;
                        video.src = originalSrc;
                        video.load();
                        video.play().catch(function() {});
                    }, delay);
                }

                // On error: attempt to reload instead of showing a permanent error
                video.addEventListener('error', function() {
                    reloadVideo();
                });

                // Also catch source-level errors (nested <source> or src attribute)
                video.addEventListener('stalled', function() {
                    // Only act if the video isn't playing
                    if (video.paused && video.readyState < 3) {
                        reloadVideo();
                    }
                });

                // Report native video dimensions to Swift once metadata is loaded
                video.addEventListener('loadedmetadata', function() {
                    if (video.videoWidth > 0 && video.videoHeight > 0 && window.webkit && window.webkit.messageHandlers.videoDimensions) {
                        window.webkit.messageHandlers.videoDimensions.postMessage({
                            width: video.videoWidth,
                            height: video.videoHeight
                        });
                    }
                });

                // Reset retry count on successful playback
                video.addEventListener('playing', function() {
                    retryCount = 0;
                });

                // Resume playback if the video randomly pauses (e.g. after space restoration)
                video.addEventListener('pause', function() {
                    // Only auto-resume when room is active
                    if (!window._roomActive) return;
                    if (!video.ended && video.readyState >= 2) {
                        setTimeout(function() {
                            if (!window._roomActive) return;
                            if (video.paused && !video.ended) {
                                video.play().catch(function() {});
                            }
                        }, 500);
                    }
                });
            </script>
        </body>
        </html>
        """
    }
}
