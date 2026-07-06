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

        // Read live (default on) so toggling the setting takes effect on next fetch.
        // Mirrors AppModel.enableStashTranscoding.
        let allowTranscoding = UserDefaults.standard.object(forKey: "enableStashTranscoding") as? Bool ?? true

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
                streamEndpoints: scene.sceneStreams,
                allowTranscoding: allowTranscoding
            )
            let fallbackStreamURL = streamURL == directStreamURL ? nil : directStreamURL

            // Prefer the server-reported preview path; otherwise derive it as a
            // sibling of the screenshot (`/scene/{id}/screenshot` → `/preview`),
            // which matches Stash's default route layout.
            let previewURL: URL? = scene.paths.preview
                .flatMap { URL(string: $0) }
                ?? Self.derivedPreviewURL(fromScreenshot: thumbnailURL)

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
                previewURL: previewURL,
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
    /// route to a server-side live-transcode endpoint, preferring HLS.
    ///
    /// HLS (`/stream.m3u8`) is a proper VOD playlist of h264/AAC mpegts
    /// segments, which AVFoundation plays natively — so it routes to the Metal
    /// renderer (GPU-private textures) and, crucially, makes fake-3D available
    /// (the pseudo-3D pipeline decodes via AVPlayerItemVideoOutput and is gated
    /// on the native renderer). The `/stream.mp4` endpoint is a *fragmented*
    /// MP4 served over a single non-seekable chunked pipe: WebKit plays it but
    /// AVPlayer rejects it (it wants a byte-range-seekable resource), which is
    /// why mp4 forces WebKit and blocks fake-3D. So prefer HLS, fall back to
    /// MP4 (WebKit-only), then direct WebM for servers without live transcode.
    private static func preferredStreamURL(
        directStreamURL: URL,
        fileName: String?,
        streamEndpoints: [StashAPIClient.StashSceneStreamEndpoint]?,
        allowTranscoding: Bool
    ) -> URL {
        let originalExtension = (fileName as NSString?)?.pathExtension.lowercased()
            ?? directStreamURL.pathExtension.lowercased()
        guard allowTranscoding,
              originalExtension == "webm",
              let streamEndpoints,
              !streamEndpoints.isEmpty else {
            return directStreamURL
        }

        let endpointURLs = streamEndpoints.compactMap { URL(string: $0.url) }

        if let hlsURL = endpointURLs.first(where: { $0.path.hasSuffix("/stream.m3u8") }) {
            return hlsURL
        }

        if let mp4URL = endpointURLs.first(where: { $0.path.hasSuffix("/stream.mp4") }) {
            return mp4URL
        }

        return directStreamURL
    }

    /// Fallback preview URL when the server didn't report `paths.preview`.
    /// Stash serves the preview as a sibling of the screenshot, so swap a
    /// trailing `/screenshot` path component for `/preview`, preserving the
    /// query string (e.g. the apikey). Returns `nil` for file URLs or paths
    /// that don't match the expected shape.
    private static func derivedPreviewURL(fromScreenshot screenshot: URL) -> URL? {
        guard !screenshot.isFileURL,
              var components = URLComponents(url: screenshot, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let suffix = "/screenshot"
        guard components.path.hasSuffix(suffix) else { return nil }
        components.path = String(components.path.dropLast(suffix.count)) + "/preview"
        return components.url
    }
}
