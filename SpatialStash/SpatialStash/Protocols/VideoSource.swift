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
}
