/*
 Spatial Stash - Remote API Client

 Actor that communicates with the RoboFrame API for image search,
 retrieval, saving, and history tracking.
 */

import Foundation
import os

actor RemoteAPIClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Strip a trailing slash so callers can safely concatenate `/search` etc.
    /// without producing `//search`. This makes both `https://host` and
    /// `https://host/` (and `https://host/subpath` / `https://host/subpath/`)
    /// behave the same.
    private nonisolated func normalize(_ baseURL: String) -> String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    // RoboFrame is the single DuckDB reader; clients receive posts over the
    // WebSocket via `playback` frames. This client just resolves /get URLs
    // and handles save/history.

    /// Build the direct image URL for a specific post.
    /// The /get endpoint serves the image directly (or redirects to it),
    /// so we construct the URL and use it as the image source.
    nonisolated func getImageURL(baseURL: String, postId: Int) -> URL? {
        URL(string: "\(normalize(baseURL))/get?id=\(postId)")
    }

    /// Save the current post on the server.
    func save(baseURL: String, postId: Int) async throws -> String {
        guard let url = URL(string: "\(normalize(baseURL))/save?id=\(postId)") else {
            throw RemoteAPIError.invalidURL
        }

        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8) ?? "Saved"
    }

    /// Add a post to the viewing history on the server.
    func addToHistory(baseURL: String, postId: Int) async throws {
        guard let url = URL(string: "\(normalize(baseURL))/addtohistory?id=\(postId)") else {
            throw RemoteAPIError.invalidURL
        }

        _ = try await session.data(from: url)
    }

    // Tag lists used to be fetched from /tags.json. They now arrive over the WebSocket
    // as a `tagLists` server→client frame on connect; see RemoteWebSocketClient.
}

enum RemoteAPIError: LocalizedError {
    case invalidURL
    case serverError
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .serverError: return "Server returned an error"
        case .invalidResponse: return "Invalid server response"
        }
    }
}

