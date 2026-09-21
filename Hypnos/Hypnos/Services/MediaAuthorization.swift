/*
 Hypnos - Media Authorization

 Maps a media server's host to the credential that authenticates requests to
 it, so "how do I attach auth to this URL" has one answer instead of a
 `?apikey=` literal hand-copied into every consumer.

 Stash and Nextcloud need genuinely different mechanisms — a query parameter
 the server itself already bakes into most URLs it hands back, versus a Basic
 `Authorization` header that has no query-string equivalent — so the type this
 resolves to is a small enum rather than a single "auth token" string, and
 each consumer asks for the *shape* it can use (a full `URLRequest`, bare
 header fields for `AVURLAsset`, or a query-decorated `URL` for a caller that
 can only hand WebKit a `src` attribute).
 */

import Foundation
import os

/// How to authenticate requests to one configured media server.
enum MediaCredential: Equatable, Sendable {
    /// Appended as a query item, e.g. Stash's `?apikey=...` — the server
    /// itself already bakes this into most URLs it returns, so this exists
    /// for the URLs the app derives client-side (transcode variants, preview
    /// clips) that don't come pre-authenticated.
    case queryParam(name: String, value: String)
    /// Sent as a request header, e.g. Nextcloud's Basic auth. Has no query
    /// form, so a consumer that can only carry a bare `URL` (an HTML5
    /// `<video src>`) cannot use this — see `MediaAuthorization.authorizedURL`.
    case header(name: String, value: String)
}

/// Resolves a URL's host to the credential that should authenticate it.
///
/// A process-wide registry rather than something threaded through every
/// loader: `ImageLoader` is a singleton actor with no reference to
/// `AppModel`, and the WebKit-hosted image/video views build their HTML
/// independent of any model. `AppModel` is the sole writer — it registers or
/// unregisters a server's credential whenever it's configured or removed —
/// and everything else only ever reads.
struct MediaAuthorization: Sendable {
    static let shared = MediaAuthorization()

    private struct Entry: Sendable {
        let host: String
        let credential: MediaCredential
    }

    private let state = OSAllocatedUnfairLock(initialState: [Entry]())

    private init() {}

    /// Registers (or replaces) the credential for `host`. `host` may be a
    /// bare hostname or a full server URL string — either way only the host
    /// component is kept, so a caller can pass the server URL it already has
    /// on hand.
    func register(host: String, credential: MediaCredential) {
        guard let normalized = normalizedHost(host) else { return }
        state.withLock { entries in
            entries.removeAll { $0.host == normalized }
            entries.append(Entry(host: normalized, credential: credential))
        }
    }

    func unregister(host: String) {
        guard let normalized = normalizedHost(host) else { return }
        state.withLock { entries in entries.removeAll { $0.host == normalized } }
    }

    func credential(for url: URL) -> MediaCredential? {
        guard let host = normalizedHost(url.host) else { return nil }
        return state.withLock { entries in entries.first { $0.host == host }?.credential }
    }

    // MARK: - Applying a credential

    /// A `URLRequest` for `url`, header-authenticated if its host has a
    /// header credential. Query-param credentials need no request-level
    /// work — the URL already carries them, either baked in by the server or
    /// via `authorizedURL` upstream — so this only ever adds a header.
    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if case .header(let name, let value) = credential(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Header fields for a consumer that can't build a `URLRequest`, namely
    /// `AVURLAsset(url:options:)`. Empty for a query-param credential or an
    /// unregistered host.
    func headerFields(for url: URL) -> [String: String] {
        guard case .header(let name, let value) = credential(for: url) else { return [:] }
        return [name: value]
    }

    /// `url` with a query-param credential appended. A header credential
    /// (Nextcloud) has no query form and is returned unchanged — a consumer
    /// that needs one authenticated must go through `request(for:)` or
    /// `headerFields(for:)` instead, or (for WebKit `<video>`/`<img>` src,
    /// which can carry neither) fetch the bytes itself and hand WebKit a
    /// blob URL, the way `AnimatedImageWebView`'s header path does.
    func authorizedURL(_ url: URL) -> URL {
        guard case .queryParam(let name, let value) = credential(for: url),
              !value.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        guard !queryItems.contains(where: { $0.name == name }) else { return url }
        queryItems.append(URLQueryItem(name: name, value: value))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        // Accept a full URL string as a convenience for callers that only
        // have the server URL on hand.
        if let parsedHost = URL(string: host)?.host { return parsedHost.lowercased() }
        return host.lowercased()
    }
}
