/*
 Spatial Stash - web-yt-dlp Client

 Builds the direct construct-and-play stream URL for a self-hosted web-yt-dlp
 instance (https://github.com/illixion/web-yt-dlp). The app does not pre-resolve
 metadata — it simply plays `{endpoint}/stream?url=<page>&token=<token>`, and the
 server runs yt-dlp + muxes + streams (with HTTP Range support) on the fly.

 The token rides as a query parameter because AVPlayer streams the URL directly
 and can't easily attach a Bearer header; web-yt-dlp's auth accepts `?token=`.
 */

import Foundation

struct WebYTDLPClient {
    let endpoint: String
    let token: String

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build `{endpoint}/stream?url=<page>&token=<token>`. Returns nil if the
    /// endpoint is empty or unparseable.
    func streamURL(forPage page: URL) -> URL? {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }

        guard var components = URLComponents(string: trimmed) else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/stream"

        var items = [URLQueryItem(name: "url", value: page.absoluteString)]
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tok.isEmpty { items.append(URLQueryItem(name: "token", value: tok)) }
        components.queryItems = items

        return components.url
    }
}
