/*
 Spatial Stash - Remote History Store

 Shared cache of the RoboFrame server's /history.json response, scoped to
 a single endpoint URL. Multiple viewer windows pointed at the same server
 read the same store, so opening the history grid in any one of them
 doesn't re-trigger a fetch the others have already done.

 Refresh policy: on app launch (eagerly per saved config) and on each
 press of the history button. The server's history is a small rolling
 window kept in RAM, so a polling/observer setup would be overkill.
 */

import Foundation
import os

@MainActor
@Observable
final class RemoteHistoryStore {
    let endpoint: String
    private let apiClient: RemoteAPIClient

    private(set) var entries: [RemoteHistoryEntry] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    /// Token captured on construction. AppModel re-creates the store if the
    /// stored config changes the token, so we don't need a setter here.
    private let accessToken: String

    init(endpoint: String, accessToken: String, apiClient: RemoteAPIClient) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.apiClient = apiClient
    }

    /// Build the /get URL for a history entry. Viewing a thumbnail must not
    /// re-record it (it would land in `others`), so recording is suppressed.
    func imageURL(for entry: RemoteHistoryEntry) -> URL? {
        apiClient.getImageURL(baseURL: endpoint, postId: entry.id, accessToken: accessToken, record: false)
    }

    func refresh() async {
        guard !endpoint.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await apiClient.fetchHistory(baseURL: endpoint, accessToken: accessToken)
            entries = fresh
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLogger.remoteViewer.error("History fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
