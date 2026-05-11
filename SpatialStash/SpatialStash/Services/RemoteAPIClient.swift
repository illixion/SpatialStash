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

    /// Append the access token as a `token` query param. The server's
    /// /get, /save, /addtohistory, /history routes all require it.
    private nonisolated func withToken(_ url: String, token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return url }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let sep = url.contains("?") ? "&" : "?"
        return "\(url)\(sep)token=\(encoded)"
    }

    /// Build the direct image URL for a specific post.
    /// The /get endpoint serves the image directly (or redirects to it),
    /// so we construct the URL and use it as the image source.
    nonisolated func getImageURL(baseURL: String, postId: Int, accessToken: String) -> URL? {
        URL(string: withToken("\(normalize(baseURL))/get?id=\(postId)", token: accessToken))
    }

    /// Save the current post on the server.
    func save(baseURL: String, postId: Int, accessToken: String) async throws -> String {
        guard let url = URL(string: withToken("\(normalize(baseURL))/save?id=\(postId)", token: accessToken)) else {
            throw RemoteAPIError.invalidURL
        }

        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8) ?? "Saved"
    }

    /// Add a post to the viewing history on the server.
    func addToHistory(baseURL: String, postId: Int, accessToken: String) async throws {
        guard let url = URL(string: withToken("\(normalize(baseURL))/addtohistory?id=\(postId)", token: accessToken)) else {
            throw RemoteAPIError.invalidURL
        }

        _ = try await session.data(from: url)
    }

    /// Fetch the server-side rolling history (most recent first). The
    /// server's RAM-resident buffer (~50 entries) is the single source of
    /// truth across all kiosks/clients, so this lets multiple viewers share
    /// the same view of "what has been shown lately" instead of each
    /// accumulating its own local list.
    func fetchHistory(baseURL: String, accessToken: String) async throws -> [RemoteHistoryEntry] {
        guard let url = URL(string: withToken("\(normalize(baseURL))/history.json", token: accessToken)) else {
            throw RemoteAPIError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RemoteAPIError.serverError
        }
        struct Payload: Decodable { let history: [RemoteHistoryEntry] }
        return try JSONDecoder().decode(Payload.self, from: data).history
    }

    // Tag lists used to be fetched from /tags.json. They now arrive over the WebSocket
    // as a `tagLists` server→client frame on connect; see RemoteWebSocketClient.
}

struct RemoteHistoryEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let ext: String
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

