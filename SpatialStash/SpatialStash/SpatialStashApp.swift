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
        Window("Spatial Stash", id: "main") {
            MainWindowView(appModel: appModel)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.presented)

        // Pushed picture viewer - replaces main window temporarily
        WindowGroup(id: "pushed-picture", for: GalleryImage.self) { $image in
            if let image = image {
                PushedPictureView(image: image)
                    .environment(appModel)
            }
        }
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        // Individual photo window - supports multiple pop-out instances
        WindowGroup(id: "photo-detail", for: GalleryImage.self) { $image in
            if let image = image {
                PhotoWindowView(image: image, appModel: appModel)
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

    var body: some View {
        ContentView()
            .environment(appModel)
            .frame(minWidth: 320, maxWidth: 2000, minHeight: 320, maxHeight: 2000)
            .onAppear {
                AppLogger.app.info("Main window appeared")
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
