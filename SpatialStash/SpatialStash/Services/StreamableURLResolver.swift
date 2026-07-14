/*
 Spatial Stash - Streamable URL Resolver

 Classifies an incoming URL (from the `spatialstash://play` custom scheme or a
 shared link) into: a directly-playable video stream, a web page (candidate for
 the web-yt-dlp proxy), or "not playable" (fall through to the existing
 image/file share path). For extensionless http(s) URLs it probes the server's
 Content-Type via a HEAD request (with a ranged-GET fallback for servers that
 reject HEAD).

 Also mints a stable identity string for a stream URL so per-video state (e.g.
 the pseudo-3D depth cache) persists across reopenings — the YouTube video ID
 when recognizable, otherwise a hash of the URL.
 */

import Foundation
import CryptoKit

enum StreamableURLResolver {
    enum Classification {
        /// A directly playable video/stream URL (file or remote).
        case directVideo(URL)
        /// An http(s) page URL — hand to web-yt-dlp when enabled.
        case webPage(URL)
        /// Not a video — let the existing image/file share path handle it.
        case notPlayable
    }

    /// Container/playlist extensions AVPlayer or the WebKit fallback can play.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp", "m3u8", "ts"
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "jxl"
    ]

    /// Classify a URL for playback routing. May perform a network probe, so call
    /// from an async context (never blocks the main actor synchronously).
    static func classify(_ url: URL) async -> Classification {
        guard let scheme = url.scheme?.lowercased() else { return .notPlayable }

        // Local files: only route obvious videos here; images fall through.
        if scheme == "file" {
            return videoExtensions.contains(url.pathExtension.lowercased())
                ? .directVideo(url) : .notPlayable
        }

        guard scheme == "http" || scheme == "https" else { return .notPlayable }

        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .directVideo(url) }
        if imageExtensions.contains(ext) { return .notPlayable }

        // Unknown / absent extension (e.g. a Discord CDN link or a bare stream
        // path) — ask the server what it is.
        if let contentType = await probeContentType(url) {
            if isPlayableVideoContentType(contentType) { return .directVideo(url) }
            if contentType.hasPrefix("image/") { return .notPlayable }
            if contentType.hasPrefix("text/") || contentType.contains("html") {
                return .webPage(url)
            }
        }
        // Inconclusive probe → treat as a web page so web-yt-dlp can attempt it,
        // rather than misrouting to the image viewer (the old default).
        return .webPage(url)
    }

    // MARK: - Content-Type probing

    private static func probeContentType(_ url: URL) async -> String? {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 8
        if let ct = await contentType(for: head) { return ct }

        // Some servers (and CDNs) reject HEAD — retry with a single-byte GET.
        var ranged = URLRequest(url: url)
        ranged.httpMethod = "GET"
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        ranged.timeoutInterval = 8
        return await contentType(for: ranged)
    }

    private static func contentType(for request: URLRequest) async -> String? {
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
    }

    private static func isPlayableVideoContentType(_ ct: String) -> Bool {
        if ct.hasPrefix("video/") { return true }
        let hls = [
            "application/vnd.apple.mpegurl", "application/x-mpegurl",
            "audio/mpegurl", "application/mpegurl"
        ]
        return hls.contains { ct.hasPrefix($0) }
    }

    // MARK: - Identity & display

    /// Stable per-video identity for `GalleryVideo.stashId`, so depth caches and
    /// enhancement tracking persist across reopenings of the same source.
    static func stableIdentity(for url: URL) -> String {
        if let ytID = youTubeID(from: url) { return "webyt:\(ytID)" }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "stream:\(hex.prefix(16))"
    }

    /// Extract a YouTube video ID from a watch / youtu.be / shorts / embed URL.
    static func youTubeID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let parts = url.pathComponents
        if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
           idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    /// Best-effort human title for the window when no metadata is available.
    static func displayTitle(for url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host ?? "Web Video"
    }
}
