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

    /// Search for posts matching tags with optional aspect ratio filtering.
    /// - Parameters:
    ///   - baseURL: The API endpoint base URL
    ///   - tags: Space-separated tag query
    ///   - ratioRange: Optional "min-max" ratio range string
    ///   - cursor: Pagination cursor from previous search
    /// - Returns: Search response with results and next cursor
    func search(baseURL: String, tags: String, ratioRange: String? = nil, cursor: String? = nil) async throws -> RemoteSearchResponse {
        var query = tags
        if let ratioRange {
            query += " ratio:\(ratioRange)"
        }
        query += " limit:20"

        // Build URL manually — URLQueryItem over-encodes characters like "="
        // inside values (e.g. "score:>=30" becomes "score:%3E%3D30" instead of
        // "score:%3E=30"), which the server doesn't understand.
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        var urlString = "\(baseURL)/search?q=\(encodedQuery)"
        if let cursor {
            urlString += "&cursor=\(cursor)"
        }

        guard let url = URL(string: urlString) else {
            throw RemoteAPIError.invalidURL
        }

        AppLogger.remoteViewer.debug("Search: \(url.absoluteString, privacy: .private)")
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.remoteViewer.error("Search HTTP \(statusCode, privacy: .public)")
            throw RemoteAPIError.serverError
        }

        do {
            return try JSONDecoder().decode(RemoteSearchResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            AppLogger.remoteViewer.error("Search decode failed: \(error, privacy: .public)\nResponse: \(preview, privacy: .private)")
            throw error
        }
    }

    /// Build the direct image URL for a specific post.
    /// The /get endpoint serves the image directly (or redirects to it),
    /// so we construct the URL and use it as the image source.
    nonisolated func getImageURL(baseURL: String, postId: Int) -> URL? {
        URL(string: "\(baseURL)/get?id=\(postId)")
    }

    /// Save the current post on the server.
    func save(baseURL: String, postId: Int) async throws -> String {
        guard let url = URL(string: "\(baseURL)/save?id=\(postId)") else {
            throw RemoteAPIError.invalidURL
        }

        let (data, _) = try await session.data(from: url)
        return String(data: data, encoding: .utf8) ?? "Saved"
    }

    /// Add a post to the viewing history on the server.
    func addToHistory(baseURL: String, postId: Int) async throws {
        guard let url = URL(string: "\(baseURL)/addtohistory?id=\(postId)") else {
            throw RemoteAPIError.invalidURL
        }

        _ = try await session.data(from: url)
    }

    /// Fetch tag lists from the server's tags.json endpoint.
    /// Returns an array of tag lists, where each list is an array of tag strings.
    func fetchTagLists(baseURL: String) async throws -> [[String]] {
        guard let url = URL(string: "\(baseURL)/tags.json") else {
            throw RemoteAPIError.invalidURL
        }

        AppLogger.remoteViewer.debug("Fetching tags.json: \(url.absoluteString, privacy: .private)")
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.remoteViewer.info("tags.json HTTP \(statusCode, privacy: .public) — not available")
            throw RemoteAPIError.serverError
        }

        // tags.json is an array of arrays: [["tag1 tag2", ...], ["tag3", ...]]
        // or an array of strings: ["tag1 tag2", "tag3 tag4"]
        // Try array-of-arrays first, then array-of-strings
        if let lists = try? JSONDecoder().decode([[String]].self, from: data) {
            return lists
        }
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            // Each string is a space-separated tag list
            return strings.map { $0.components(separatedBy: " ").filter { !$0.isEmpty } }
        }

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        AppLogger.remoteViewer.error("tags.json decode failed. Response: \(preview, privacy: .private)")
        throw RemoteAPIError.invalidResponse
    }
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

private extension CharacterSet {
    /// Characters safe in a URL query value. Keeps `=`, `:`, `>`, `<`, `/`
    /// unencoded since the RoboFrame server expects them literal — unlike
    /// URLQueryItem which over-encodes `=` inside values.
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&+")
        return cs
    }()
}
