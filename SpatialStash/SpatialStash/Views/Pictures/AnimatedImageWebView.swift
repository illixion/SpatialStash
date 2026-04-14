/*
 Spatial Stash - Animated Image Web View

 WKWebView-based animated image renderer for formats like animated WebP.
 Loads the image from its direct URL to preserve browser-native animation.
 */

import SwiftUI
import WebKit

struct AnimatedImageWebView: UIViewRepresentable {
    enum ElementType: String {
        case image
        case video
    }

    let imageURL: URL
    var elementType: ElementType = .image
    var apiKey: String?
    var authorizationToken: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let digest = imageURL.absoluteString.hashValue
            ^ elementType.rawValue.hashValue
            ^ (apiKey ?? "").hashValue
            ^ (authorizationToken ?? "").hashValue
        guard context.coordinator.loadedDigest != digest else { return }
        context.coordinator.loadedDigest = digest

        loadMedia(webView: webView)
    }

    private func loadMedia(webView: WKWebView) {
        if imageURL.isFileURL {
            let htmlFile = imageURL.deletingLastPathComponent().appendingPathComponent(".spatialstash_animated_asset.html")
            try? htmlForLocalFile(relativePath: imageURL.lastPathComponent).write(to: htmlFile, atomically: true, encoding: .utf8)
            webView.loadFileURL(htmlFile, allowingReadAccessTo: imageURL.deletingLastPathComponent())
            return
        }

        let resolvedURL = resolvedRemoteURL() ?? imageURL
        let html = authorizationToken?.isEmpty == false
            ? htmlForRemoteFetch(url: resolvedURL, bearerToken: authorizationToken ?? "")
            : htmlForRemoteSource(url: resolvedURL)
        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator {
        var loadedDigest: Int?
    }

    private func resolvedRemoteURL() -> URL? {
        guard !imageURL.isFileURL else { return imageURL }

        guard let apiKey, !apiKey.isEmpty,
              var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false) else {
            return imageURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = queryItems
        return components.url
    }

    private func mediaElementMarkup(source: String, isObjectURL: Bool) -> String {
        switch elementType {
        case .image:
            let srcAttribute = isObjectURL ? "" : "src=\"\(source)\""
            return "<img id=\"media\" \(srcAttribute) alt=\"animated media\" draggable=\"false\" />"
        case .video:
            let srcAttribute = isObjectURL ? "" : "src=\"\(source)\""
            return "<video id=\"media\" \(srcAttribute) autoplay loop muted playsinline></video>"
        }
    }

    private func sharedHTML(body: String, script: String = "") -> String {
        """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background: transparent;
                }
                .wrap {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background: transparent;
                }
                #media {
                    display: block;
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: transparent;
                }
            </style>
        </head>
        <body>
            <div class="wrap">
                \(body)
            </div>
            <script>
                \(script)
            </script>
        </body>
        </html>
        """
    }

    private func htmlForLocalFile(relativePath: String) -> String {
        sharedHTML(body: mediaElementMarkup(source: relativePath, isObjectURL: false))
    }

    private func htmlForRemoteSource(url: URL) -> String {
        sharedHTML(body: mediaElementMarkup(source: url.absoluteString.jsEscapedForSingleQuotedString, isObjectURL: false))
    }

    private func htmlForRemoteFetch(url: URL, bearerToken: String) -> String {
        let escapedURL = url.absoluteString.jsEscapedForSingleQuotedString
        let escapedToken = bearerToken.jsEscapedForSingleQuotedString
        let body = mediaElementMarkup(source: "", isObjectURL: true)
        let script = """
        (async function() {
            const response = await fetch('\(escapedURL)', {
                headers: { Authorization: 'Bearer \(escapedToken)' }
            });
            const blob = await response.blob();
            const objectURL = URL.createObjectURL(blob);
            const media = document.getElementById('media');
            media.src = objectURL;
            if (media.tagName === 'VIDEO') {
                media.play().catch(function() {});
            }
        })();
        """
        return sharedHTML(body: body, script: script)
    }
}

private extension String {
    var jsEscapedForSingleQuotedString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
