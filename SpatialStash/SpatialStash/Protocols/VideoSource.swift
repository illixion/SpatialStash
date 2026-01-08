/*
 Spatial Stash - Video Source Protocol

 Protocol for fetching videos from various sources.
 */

import Foundation

/// Result of a video fetch operation
struct VideoFetchResult {
    let videos: [GalleryVideo]
    let hasMore: Bool
    let totalCount: Int?

    init(videos: [GalleryVideo], hasMore: Bool, totalCount: Int? = nil) {
        self.videos = videos
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

/// Protocol for video sources
protocol VideoSource: Sendable {
    /// Fetch a page of videos
    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult

    /// Fetch a page of videos with filter criteria
    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult
}

// Default implementation for sources that don't support filtering
extension VideoSource {
    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        // Default: ignore filter and fetch all
        return try await fetchVideos(page: page, pageSize: pageSize)
    }
}
