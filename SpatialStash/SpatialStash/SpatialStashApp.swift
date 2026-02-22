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
        WindowGroup("Spatial Stash", id: "main") {
            MainWindowView(appModel: appModel)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
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
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentView()
            .environment(appModel)
            .frame(minWidth: 320, maxWidth: 2000, minHeight: 320, maxHeight: 2000)
            .onAppear {
                if appModel.isMainWindowOpen {
                    // Duplicate main window (e.g. from restoration) — dismiss it
                    AppLogger.app.info("Duplicate main window detected, dismissing")
                    dismissWindow(id: "main")
                    return
                }
                appModel.isMainWindowOpen = true
                AppLogger.app.info("Main window appeared")
            }
            .onDisappear {
                appModel.isMainWindowOpen = false
            }
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
