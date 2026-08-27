/*
 Spatial Stash - App Entry Point

 Vision Pro app for viewing photos with 2D to 3D spatial conversion.
 */

import os
import RAVEUI
import SwiftUI

@main
struct SpatialStashApp: App {
    @State private var appModel: AppModel
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    /// Written out rather than left to a property initializer so the UI-testing
    /// overrides land *before* `AppModel.init` reads UserDefaults. A default
    /// value expression is evaluated ahead of the initializer body, so
    /// `appModel = AppModel()` as a default would win the race.
    init() {
        #if DEBUG
        UITestingConfiguration.applyIfNeeded()
        #endif
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        // Main gallery window — WindowGroup allows multiple instances.
        // UUID identity ensures each openWindow call creates a new window.
        WindowGroup("Spatial Stash", id: "main", for: UUID.self) { $windowId in
            // Main windows are managed too (inside `MainWindowView`): the app
            // opens several, and one parked in another room is exactly what the
            // Windows tab is for. Each tab lists every main window but its own.
            MainWindowView(appModel: appModel, windowId: windowId)
                .handleIncomingMediaURLs(appModel: appModel)
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
                    $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
                })
                    .environment(appModel)
                    .captureOpenWindowAction()
                    .handleIncomingMediaURLs(appModel: appModel)
                    .manageWindow(ManagedWindows.photo(windowValue))
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
                    .handleIncomingMediaURLs(appModel: appModel)
                    .manageWindow(ManagedWindows.video(windowValue))
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
                    .handleIncomingMediaURLs(appModel: appModel)
                    .manageWindow(ManagedWindows.sharedPhoto(item))
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Shared videos are routed to the "video-detail" scene above (rich
        // pipeline: native-Metal playback, fake-3D, adjustments). The old flat
        // "shared-video" group is gone — nothing opened it, and a second
        // WindowGroup taking the same `SharedMediaItem` payload made scene
        // restoration ambiguous between it and "shared-photo".

        // Pop-out debug console window (singleton)
        Window("Console", id: "console") {
            ConsoleWindowView()
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .manageWindow(ManagedWindows.console())
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // GPU memory monitor window (singleton)
        Window("GPU Memory", id: "gpu-memory") {
            GPUMemoryMonitorView()
                .environment(appModel)
                .captureOpenWindowAction()
                .handleIncomingMediaURLs(appModel: appModel)
                .manageWindow(ManagedWindows.gpuMemory())
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
                .handleIncomingMediaURLs(appModel: appModel)
                .manageWindow(ManagedWindows.videoAdjustments())
        }
        .defaultSize(width: 380, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Remote viewer - RoboFrame/gallery slideshow, or a pinned web page
        // (the profile's `mode` decides; see RemoteViewerSceneRoot).
        WindowGroup(id: "remote-viewer", for: RemoteViewerWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                RemoteViewerSceneRoot(windowValue: windowValue, appModel: appModel, onSizeSettled: { size in
                    $windowValue.wrappedValue?.restoredSize = RAVECodableSize(size)
                })
                    .environment(appModel)
                    .captureOpenWindowAction()
                    .handleIncomingMediaURLs(appModel: appModel)
                    .manageWindow(ManagedWindows.remoteViewer(windowValue, appModel: appModel))
                    // Structural floor. This view's root is a GeometryReader,
                    // which has no intrinsic size and greedily accepts whatever
                    // it's proposed — during restoration of a window the
                    // compositor hasn't placed yet, that proposal can be the
                    // 10x10 default. Without a minimum the window collapses to
                    // nothing, and the size write-back then persists the
                    // collapsed geometry. The main window group has had this
                    // floor all along; the viewer was the one scene without it.
                    .frame(
                        minWidth: RemoteViewerWindowView.minimumWindowSize.width,
                        minHeight: RemoteViewerWindowView.minimumWindowSize.height
                    )
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1400, height: 900)
        .defaultLaunchBehavior(.suppressed)

        // Remote alert - WebSocket-triggered text alerts
        WindowGroup(id: "remote-alert", for: RemoteAlertWindowValue.self) { $windowValue in
            if let windowValue = windowValue {
                RemoteAlertWindowView(windowValue: windowValue)
                    .captureOpenWindowAction()
                    .handleIncomingMediaURLs(appModel: appModel)
                    .manageWindow(ManagedWindows.remoteAlert(windowValue))
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
    /// The scene's presented value. Unreachable as nil in practice — the group
    /// declares a `defaultValue` — but the binding is optional, so the window
    /// manager needs an identity that survives body re-evaluation either way:
    /// a fresh `UUID()` per evaluation would leave Close addressing a value no
    /// scene holds.
    let windowId: UUID?
    @State private var fallbackWindowId = UUID()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(appModel)
            .frame(minWidth: 320, maxWidth: 3000, minHeight: 320, maxHeight: 3000)
            .registerAsMainWindow()
            .manageWindow(ManagedWindows.main(windowId ?? fallbackWindowId))
            .onAppear {
                RAVEWindowSessionRegistry.shared.openWindow = openWindow
            }
    }
}
