/*
 Spatial Stash - GraphQL Video Source

 VideoSource implementation that fetches scenes from Stash server via GraphQL.
 */

import Foundation

/// Video source that fetches from Stash GraphQL API
final class GraphQLVideoSource: VideoSource, @unchecked Sendable {
    private let apiClient: StashAPIClient

    init(apiClient: StashAPIClient) {
        self.apiClient = apiClient
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        // Stash uses 1-indexed pages
        let stashPage = page + 1
        print("[GraphQLVideoSource] Fetching videos page \(stashPage), pageSize \(pageSize)")

        let result = try await apiClient.findScenes(page: stashPage, perPage: pageSize)
        print("[GraphQLVideoSource] Got \(result.scenes.count) scenes, total: \(result.count)")

        let videos = result.scenes.compactMap { scene -> GalleryVideo? in
            guard let streamURLString = scene.paths.stream,
                  let streamURL = URL(string: streamURLString) else {
                return nil
            }

            let thumbnailURL: URL
            if let screenshotString = scene.paths.screenshot,
               let screenshotURL = URL(string: screenshotString) {
                thumbnailURL = screenshotURL
            } else {
                // Use a placeholder or first frame
                thumbnailURL = streamURL
            }

            let duration = scene.files?.first?.duration

            return GalleryVideo(
                stashId: scene.id,
                thumbnailURL: thumbnailURL,
                streamURL: streamURL,
                title: scene.title,
                duration: duration
            )
        }

        let totalPages = (result.count + pageSize - 1) / pageSize
        let hasMore = (page + 1) < totalPages

        return VideoFetchResult(
            videos: videos,
            hasMore: hasMore,
            totalCount: result.count
        )
    }
}
