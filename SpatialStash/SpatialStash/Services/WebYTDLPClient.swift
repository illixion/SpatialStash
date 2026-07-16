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

    /// The encoding preset requested from web-yt-dlp. Spatial Stash only ever
    /// runs on Apple platforms, so HEVC (`h265`) is the default: smaller files
    /// at higher quality, tagged `hvc1` so AVPlayer's native path accepts it.
    /// web-yt-dlp stream-copies the source when it's already HEVC, so this is
    /// free when the source allows it and a hardware transcode otherwise.
    static let defaultPreset = "h265"

    /// The max video height requested from web-yt-dlp. Vision Pro's displays are
    /// high-resolution, so default to 2160 (4K) — the server caps at 2160 and
    /// picks the best source track at or below it.
    static let defaultHeight = 2160

    /// Build `{endpoint}/stream?url=<page>&token=<token>&preset=<preset>&height=<height>`.
    /// Returns nil if the endpoint is empty or unparseable.
    func streamURL(
        forPage page: URL,
        preset: String = WebYTDLPClient.defaultPreset,
        height: Int = WebYTDLPClient.defaultHeight
    ) -> URL? {
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
        let presetValue = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !presetValue.isEmpty { items.append(URLQueryItem(name: "preset", value: presetValue)) }
        if height > 0 { items.append(URLQueryItem(name: "height", value: String(height))) }
        components.queryItems = items

        return components.url
    }
}
