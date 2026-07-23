/*
 Spatial Stash - Incoming URL Handler

 Handles `spatialstash://play` handoffs and shared-media URLs from ANY open
 window — not just the main gallery window. Previously the `.onOpenURL` /
 shared-URL-notification subscribers lived only on the main window, so a handoff
 was dropped whenever no main window was mounted (e.g. only a remote slideshow
 or console window open): the SceneDelegate received the URL but nothing was
 listening. Applying this modifier to every non-immersive scene root guarantees
 a live handler; AppModel's `shouldProcessIncomingURL` dedup collapses the
 resulting multi-scene / multi-path duplicate deliveries into one window.
 */

import os
import SwiftUI

struct IncomingURLHandler: ViewModifier {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                Task { @MainActor in await handle(url) }
            }
            // SceneDelegate forwards share-sheet / cold-launch URLs that
            // `.onOpenURL` can miss when a custom UIWindowSceneDelegate is
            // installed. Broadcast to every mounted handler; dedup collapses.
            .onReceive(NotificationCenter.default.publisher(for: SceneDelegate.sharedURLNotification)) { notif in
                guard let url = notif.object as? URL else { return }
                Task { @MainActor in await handle(url) }
            }
    }

    @MainActor
    private func handle(_ url: URL) async {
        // Both `.onOpenURL` and the SceneDelegate notification — and now every
        // open window — can deliver the same URL, so drop duplicates.
        guard appModel.shouldProcessIncomingURL(url) else {
            AppLogger.streamURL.info("Ignoring duplicate incoming URL: \(url.absoluteString, privacy: .public)")
            return
        }

        // Custom handoff scheme: spatialstash://<host>?...
        if url.scheme?.lowercased() == "spatialstash" {
            switch url.host?.lowercased() {
            case "image":
                await openStashImage(from: url)
            case "scene", "video":
                await openStashScene(from: url)
            case "play", nil, "":
                // spatialstash://play?url=<percent-encoded URL>
                guard let target = Self.playTargetURL(from: url) else {
                    AppLogger.streamURL.error("spatialstash:// URL had no valid 'url' parameter: \(url.absoluteString, privacy: .public)")
                    return
                }
                await route(target)
            default:
                AppLogger.streamURL.error("Unrecognised spatialstash:// host: \(url.absoluteString, privacy: .public)")
            }
            return
        }
        await route(url)
    }

    /// Open a Stash image by ID: `spatialstash://image?id=<stashId>`.
    /// Fetches the image via GraphQL and opens it in the photo detail window,
    /// bypassing gallery UI automation (used for fast on-device testing).
    @MainActor
    private func openStashImage(from url: URL) async {
        guard let id = Self.idParameter(from: url) else {
            AppLogger.streamURL.error("spatialstash://image had no 'id' parameter: \(url.absoluteString, privacy: .public)")
            return
        }
        do {
            let source = GraphQLImageSource(apiClient: appModel.apiClient)
            guard let image = try await source.fetchImage(id: id) else {
                AppLogger.streamURL.error("No Stash image found for id \(id, privacy: .public)")
                return
            }
            openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
            AppLogger.streamURL.info("Opened Stash image \(id, privacy: .public) via callback URL")
        } catch {
            AppLogger.streamURL.error("Failed to fetch Stash image \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open a Stash scene by ID: `spatialstash://scene?id=<stashId>` (also `video`).
    @MainActor
    private func openStashScene(from url: URL) async {
        guard let id = Self.idParameter(from: url) else {
            AppLogger.streamURL.error("spatialstash://scene had no 'id' parameter: \(url.absoluteString, privacy: .public)")
            return
        }
        do {
            let source = GraphQLVideoSource(apiClient: appModel.apiClient)
            guard let video = try await source.fetchVideo(id: id) else {
                AppLogger.streamURL.error("No Stash scene found for id \(id, privacy: .public)")
                return
            }
            openWindow(id: "video-detail", value: VideoWindowValue(video: video, galleryVideos: [video]))
            AppLogger.streamURL.info("Opened Stash scene \(id, privacy: .public) via callback URL")
        } catch {
            AppLogger.streamURL.error("Failed to fetch Stash scene \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Extract the `id` query parameter from a `spatialstash://image|scene?id=` URL.
    private static func idParameter(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Route an incoming URL. Remote http(s) URLs try the rich video pipeline
    /// (direct stream) or web-yt-dlp (web page); everything else (local files)
    /// uses the shared-media cache path.
    @MainActor
    private func route(_ url: URL) async {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            switch await StreamableURLResolver.classify(url) {
            case .directVideo(let videoURL):
                openStreamVideo(videoURL, identitySource: url)
            case .webPage(let pageURL):
                guard appModel.webYTDLPEnabled else {
                    AppLogger.streamURL.info("Web page received but web-yt-dlp disabled; ignoring: \(pageURL.absoluteString, privacy: .public)")
                    return
                }
                guard let stream = appModel.webYTDLPClient.streamURL(
                    forPage: pageURL,
                    preset: appModel.webYTDLPPreset,
                    height: appModel.webYTDLPHeight
                ) else {
                    AppLogger.streamURL.error("web-yt-dlp endpoint not configured; cannot play: \(pageURL.absoluteString, privacy: .public)")
                    return
                }
                // Identity keys off the original page URL (stable per video, so
                // depth caches persist), but playback uses the proxied stream.
                openStreamVideo(stream, identitySource: pageURL)
            case .notPlayable:
                AppLogger.streamURL.info("Remote URL not playable as video; ignoring: \(url.absoluteString, privacy: .public)")
            }
        } else {
            await handleSharedFile(url)
        }
    }

    /// Open a streamable video URL in the rich pipeline (native-Metal / pseudo-3D
    /// aware). `identitySource` is the URL used to derive the stable per-video id.
    @MainActor
    private func openStreamVideo(_ streamURL: URL, identitySource: URL) {
        let video = GalleryVideo(
            stashId: StreamableURLResolver.stableIdentity(for: identitySource),
            thumbnailURL: streamURL,   // placeholder; no gallery grid on direct-open
            streamURL: streamURL,
            title: StreamableURLResolver.displayTitle(for: identitySource)
        )
        openWindow(id: "video-detail", value: VideoWindowValue(video: video, galleryVideos: [video]))
        AppLogger.streamURL.info("Opened stream video window: \(video.stashId, privacy: .public)")
    }

    /// Local file shares (file:// URLs): cache to app storage, then open images
    /// in the shared-photo viewer and videos in the rich video pipeline.
    @MainActor
    private func handleSharedFile(_ url: URL) async {
        let mediaType = SharedMediaItem.SharedMediaType.from(url: url)

        guard let result = await SharedMediaCache.shared.cacheSharedFile(
            from: url,
            mediaType: mediaType
        ) else {
            AppLogger.sharedMedia.error("Failed to cache shared file from URL: \(url.lastPathComponent, privacy: .public)")
            return
        }

        switch mediaType {
        case .image:
            let item = SharedMediaItem(
                id: result.windowId,
                cachedFileURL: result.cachedURL,
                originalFileName: url.lastPathComponent,
                mediaType: mediaType
            )
            openWindow(id: "shared-photo", value: item)
        case .video:
            // Route shared video files through the rich pipeline so pseudo-3D
            // and adjustments are available (was: flat shared-video player).
            openStreamVideo(result.cachedURL, identitySource: url)
        }

        AppLogger.sharedMedia.info("Opened shared \(mediaType.rawValue, privacy: .public): \(url.lastPathComponent, privacy: .public)")
    }

    /// Extract the inner target from `spatialstash://play?url=<encoded>`.
    private static func playTargetURL(from url: URL) -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

extension View {
    /// Handle `spatialstash://play` handoffs and shared-media URLs from this
    /// scene. Apply to every non-immersive window root so handoffs work no
    /// matter which window is open.
    func handleIncomingMediaURLs(appModel: AppModel) -> some View {
        modifier(IncomingURLHandler(appModel: appModel))
    }
}
