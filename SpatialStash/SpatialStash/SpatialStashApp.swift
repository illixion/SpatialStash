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
            ContentView()
                .environment(appModel)
                .frame(minWidth: 320, maxWidth: 2000, minHeight: 320, maxHeight: 2000)
                .onAppear {
                    // Ensure main window is visible when app launches
                    AppLogger.app.info("Main window appeared")
                }
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

        // Immersive space for stereoscopic 3D video playback
        ImmersiveSpace(id: "StereoscopicVideoSpace") {
            ImmersiveVideoView()
                .environment(appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
