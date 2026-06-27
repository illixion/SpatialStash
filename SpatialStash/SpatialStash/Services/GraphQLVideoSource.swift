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
        AppLogger.graphQLVideo.log(level: AppLogger.effectiveDebugLevel, "Fetching videos page \(stashPage, privacy: .public), pageSize \(pageSize, privacy: .public), hasFilter: \(filter != nil, privacy: .public)")

        let result = try await apiClient.findScenes(page: stashPage, perPage: pageSize, filter: filter)
        AppLogger.graphQLVideo.log(level: AppLogger.effectiveDebugLevel, "Got \(result.scenes.count, privacy: .public) scenes, total: \(result.count, privacy: .public)")

        let videos = result.scenes.compactMap { scene -> GalleryVideo? in
            guard let streamURLString = scene.paths.stream,
                  let directStreamURL = URL(string: streamURLString) else {
                return nil
            }

            let thumbnailURL: URL
            if let screenshotString = scene.paths.screenshot,
               let screenshotURL = URL(string: screenshotString) {
                thumbnailURL = screenshotURL
            } else {
                // Use a placeholder or first frame
                thumbnailURL = directStreamURL
            }

            let firstFile = scene.files?.first
            let duration = firstFile?.duration
            let sourceWidth = firstFile?.width
            let sourceHeight = firstFile?.height

            // Extract original filename from files path
            let fileName = firstFile?.path.map { ($0 as NSString).lastPathComponent }
            let streamURL = Self.preferredStreamURL(
                directStreamURL: directStreamURL,
                fileName: fileName,
                streamEndpoints: scene.sceneStreams
            )
            let fallbackStreamURL = streamURL == directStreamURL ? nil : directStreamURL

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
                fallbackStreamURL: fallbackStreamURL,
                title: scene.title,
                duration: duration,
                isStereoscopic: isStereoscopic,
                stereoscopicFormat: stereoscopicFormat,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                eyesReversed: eyesReversed,
                rating100: scene.rating100,
                oCounter: scene.o_counter,
                fileName: fileName
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

    /// Stash's direct `/stream` endpoint may serve WebM with VP8/AV1/etc. that
    /// visionOS WebKit cannot reliably decode. When the original file is WebM,
    /// prefer Stash's server-side MP4 live-transcode endpoint and keep direct
    /// WebM as fallback for servers without live transcoding.
    private static func preferredStreamURL(
        directStreamURL: URL,
        fileName: String?,
        streamEndpoints: [StashAPIClient.StashSceneStreamEndpoint]?
    ) -> URL {
        let originalExtension = (fileName as NSString?)?.pathExtension.lowercased()
            ?? directStreamURL.pathExtension.lowercased()
        guard originalExtension == "webm",
              let streamEndpoints,
              !streamEndpoints.isEmpty else {
            return directStreamURL
        }

        if let mp4URL = streamEndpoints
            .compactMap({ URL(string: $0.url) })
            .first(where: { $0.path.hasSuffix("/stream.mp4") }) {
            return mp4URL
        }

        if let hlsURL = streamEndpoints
            .compactMap({ URL(string: $0.url) })
            .first(where: { $0.path.hasSuffix("/stream.m3u8") }) {
            return hlsURL
        }

        return directStreamURL
    }
}
