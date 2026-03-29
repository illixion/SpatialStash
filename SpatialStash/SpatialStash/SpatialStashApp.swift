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
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)

        // Individual photo window - supports multiple pop-out instances
        WindowGroup(id: "photo-detail", for: PhotoWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                PhotoWindowView(windowValue: windowValue, appModel: appModel)
                    .environment(appModel)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Individual video window - pop-out video player
        WindowGroup(id: "video-detail", for: VideoWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                VideoWindowView(windowValue: windowValue)
                    .environment(appModel)
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
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 700)
        .defaultLaunchBehavior(.suppressed)

        // Pop-out debug console window (singleton)
        Window("Console", id: "console") {
            ConsoleWindowView()
                .environment(appModel)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // GPU memory monitor window (singleton)
        Window("GPU Memory", id: "gpu-memory") {
            GPUMemoryMonitorView()
                .environment(appModel)
        }
        .defaultSize(width: 500, height: 350)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // Immersive space for stereoscopic 3D video playback
        ImmersiveSpace(id: "StereoscopicVideoSpace") {
            ImmersiveVideoView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
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
            .onOpenURL { url in
                Task { @MainActor in
                    await handleIncomingURL(url)
                }
            }
    }

    private func handleIncomingURL(_ url: URL) async {
        let mediaType = SharedMediaItem.SharedMediaType.from(url: url)

        guard let result = await SharedMediaCache.shared.cacheSharedFile(
            from: url,
            mediaType: mediaType
        ) else {
            AppLogger.sharedMedia.error("Failed to cache shared file from URL: \(url.lastPathComponent, privacy: .public)")
            return
        }

        let item = SharedMediaItem(
            id: result.windowId,
            cachedFileURL: result.cachedURL,
            originalFileName: url.lastPathComponent,
            mediaType: mediaType
        )

        switch mediaType {
        case .image:
            openWindow(id: "shared-photo", value: item)
        case .video:
            openWindow(id: "shared-video", value: item)
        }

        AppLogger.sharedMedia.info("Opened shared \(mediaType.rawValue, privacy: .public): \(url.lastPathComponent, privacy: .public)")
    }
}
