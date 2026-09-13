/*
 Hypnos - Streamable URL Resolver

 Classifies an incoming URL (from the `hypnos://play` custom scheme or a
 shared link) into a directly-playable video stream or "not playable" (fall
 through to the existing image/file share path). For extensionless http(s) URLs
 it probes the server's Content-Type via a HEAD request (with a ranged-GET
 fallback for servers that reject HEAD).

 Only *direct* streams are routed here. Extracting a playable stream out of an
 arbitrary web page is deliberately out of scope — that lives in a separate app.
 A page URL classifies as `.notPlayable`.

 Also mints a stable identity string for a stream URL so per-video state (e.g.
 the pseudo-3D depth cache) persists across reopenings.
 */

import Foundation
import CryptoKit

enum StreamableURLResolver {
    enum Classification {
        /// A directly playable video/stream URL (file or remote).
        case directVideo(URL)
        /// Not a directly playable video — let the existing image/file share
        /// path handle it. Web pages land here too.
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
        if let contentType = await probeContentType(url),
           isPlayableVideoContentType(contentType) {
            return .directVideo(url)
        }
        // Anything else — a page, an image, or an inconclusive probe — is not a
        // direct stream. Better to fall through than to misroute.
        return .notPlayable
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

    /// Stable per-video identity for a streamed source, so depth caches and
    /// enhancement tracking persist across reopenings of the same URL.
    static func stableIdentity(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "stream:\(hex.prefix(16))"
    }

    /// Best-effort human title for the window when no metadata is available.
    static func displayTitle(for url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host ?? "Web Video"
    }
}
