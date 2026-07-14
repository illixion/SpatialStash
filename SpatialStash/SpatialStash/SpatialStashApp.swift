/*
 Spatial Stash - App Entry Point

 Vision Pro app for viewing photos with 2D to 3D spatial conversion.
 */

import os
import SwiftUI

@main
struct SpatialStashApp: App {
    @State private var appModel = AppModel()
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Main gallery window — WindowGroup allows multiple instances.
        // UUID identity ensures each openWindow call creates a new window.
        WindowGroup("Spatial Stash", id: "main", for: UUID.self) { $windowId in
            MainWindowView(appModel: appModel)
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.presented)

        // Individual photo window - supports multiple pop-out instances
        WindowGroup(id: "photo-detail", for: PhotoWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                PhotoWindowView(windowValue: windowValue, appModel: appModel, onSizeSettled: { size in
                    $windowValue.wrappedValue?.restoredSize = CodableSize(size)
                })
                    .environment(appModel)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Individual video window - pop-out video player
        WindowGroup(id: "video-detail", for: VideoWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                VideoWindowView(windowValue: windowValue, appModel: appModel)
                    .environment(appModel)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 700)
        .defaultLaunchBehavior(.suppressed)

        // Shared photo viewer - opens when image is shared to the app
        WindowGroup(id: "shared-photo", for: SharedMediaItem.self) { $item in
            if let item = item {
                SharedPhotoWindowView(item: item, appModel: appModel)
                    .environment(appModel)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Shared video player - opens when video is shared to the app
        WindowGroup(id: "shared-video", for: SharedMediaItem.self) { $item in
            if let item = item {
                SharedVideoWindowView(item: item)
                    .environment(appModel)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 700)
        .defaultLaunchBehavior(.suppressed)

        // Pop-out debug console window (singleton)
        Window("Console", id: "console") {
            ConsoleWindowView()
                .environment(appModel)
                .captureOpenWindowAction()
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // GPU memory monitor window (singleton)
        Window("GPU Memory", id: "gpu-memory") {
            GPUMemoryMonitorView()
                .environment(appModel)
                .captureOpenWindowAction()
        }
        .defaultSize(width: 500, height: 350)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // Video adjustments — standalone, repositionable window for the active
        // video window's Adjustments (avoids overlapping the fake-3D video).
        Window("Adjustments", id: "video-adjustments") {
            VideoAdjustmentsWindowView()
                .environment(appModel)
                .captureOpenWindowAction()
        }
        .defaultSize(width: 380, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Remote viewer - slideshow from RoboFrame API
        WindowGroup(id: "remote-viewer", for: RemoteViewerWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                RemoteViewerWindowView(windowValue: windowValue, onSizeSettled: { size in
                    $windowValue.wrappedValue?.restoredSize = CodableSize(size)
                })
                    .environment(appModel)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1400, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Remote alert - WebSocket-triggered text alerts
        WindowGroup(id: "remote-alert", for: RemoteAlertWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                RemoteAlertWindowView(windowValue: windowValue)
                    .captureOpenWindowAction()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 800, height: 500)
        .defaultLaunchBehavior(.suppressed)

        // Immersive space for stereoscopic 3D video playback
        ImmersiveSpace(id: "StereoscopicVideoSpace") {
            ImmersiveVideoView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)

        // Mixed immersive space for the "Fully Immersive 3D" photo viewer mode.
        // Opened by PhotoDisplayView when AppModel.fullyImmersive3DMode is on
        // and the user enters Immersive 3D; passes the source image URL via
        // the standard ImmersiveSpace value channel.
        ImmersiveSpace(id: "Spatial3DImmersiveSpace", for: Spatial3DImmersiveValue.self) { value in
            if let value = value.wrappedValue {
                Spatial3DImmersiveView(value: value)
                    .environment(appModel)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// Wrapper view for the main window that handles shared media URLs
private struct MainWindowView: View {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(appModel)
            .frame(minWidth: 320, maxWidth: 3000, minHeight: 320, maxHeight: 3000)
            .onAppear {
                WindowSessionRegistry.shared.registerMainWindow()
                WindowSessionRegistry.shared.openWindow = openWindow
            }
            .onDisappear {
                WindowSessionRegistry.shared.unregisterMainWindow()
            }
            .onOpenURL { url in
                Task { @MainActor in
                    await handleIncomingURL(url)
                }
            }
            // Belt-and-suspenders: when a custom UIWindowSceneDelegate is
            // installed (as we have for windowScene tracking), SwiftUI's
            // .onOpenURL can miss share-sheet handoffs. SceneDelegate
            // forwards via this notification.
            .onReceive(NotificationCenter.default.publisher(for: SceneDelegate.sharedURLNotification)) { notif in
                guard let url = notif.object as? URL else { return }
                Task { @MainActor in
                    await handleIncomingURL(url)
                }
            }
    }

    private func handleIncomingURL(_ url: URL) async {
        // Custom handoff scheme: spatialstash://play?url=<percent-encoded URL>
        if url.scheme?.lowercased() == "spatialstash" {
            guard let target = Self.playTargetURL(from: url) else {
                AppLogger.streamURL.error("spatialstash:// URL had no valid 'url' parameter: \(url.absoluteString, privacy: .public)")
                return
            }
            await route(target)
            return
        }
        await route(url)
    }

    /// Route an incoming URL. Remote http(s) URLs try the rich video pipeline
    /// (direct stream) or web-yt-dlp (web page); everything else (local files)
    /// uses the shared-media cache path.
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
                guard let stream = appModel.webYTDLPClient.streamURL(forPage: pageURL) else {
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
