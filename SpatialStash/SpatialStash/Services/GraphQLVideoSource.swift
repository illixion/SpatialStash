/*
 Spatial Stash - GraphQL Video Source

 VideoSource implementation that fetches scenes from Stash server via GraphQL.
 */

import Foundation
import os

/// Video source that fetches from Stash GraphQL API
final class GraphQLVideoSource: VideoSource, @unchecked Sendable {
    private let apiClient: StashAPIClient

    init(apiClient: StashAPIClient) {
        self.apiClient = apiClient
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        // Stash uses 1-indexed pages
        let stashPage = page + 1
        AppLogger.graphQLVideo.debug("Fetching videos page \(stashPage, privacy: .public), pageSize \(pageSize, privacy: .public), hasFilter: \(filter != nil, privacy: .public)")

        let result = try await apiClient.findScenes(page: stashPage, perPage: pageSize, filter: filter)
        AppLogger.graphQLVideo.debug("Got \(result.scenes.count, privacy: .public) scenes, total: \(result.count, privacy: .public)")

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
            let sourceWidth = scene.files?.first?.width
            let sourceHeight = scene.files?.first?.height

            // Detect stereoscopic format from tags
            let tagNames = scene.tags?.map { $0.name } ?? []
            let (isStereoscopic, stereoscopicFormat) = StereoscopicFormat.detect(from: tagNames)

            // Check for eyes reversed tag (for videos with swapped left/right eyes)
            let eyesReversed = tagNames.contains { tag in
                let lowercased = tag.lowercased()
                return lowercased == "stereo_eyes_reversed" ||
                       lowercased == "stereo-eyes-reversed" ||
                       lowercased == "eyes_reversed" ||
                       lowercased == "eyes-reversed"
            }

            return GalleryVideo(
                stashId: scene.id,
                thumbnailURL: thumbnailURL,
                streamURL: streamURL,
                title: scene.title,
                duration: duration,
                isStereoscopic: isStereoscopic,
                stereoscopicFormat: stereoscopicFormat,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                eyesReversed: eyesReversed,
                rating100: scene.rating100,
                oCounter: scene.o_counter
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
