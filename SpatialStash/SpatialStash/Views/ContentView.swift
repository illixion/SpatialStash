/*
 Spatial Stash - Content View

 Root view with tab-based content switching and ornament navigation.
 */

import RAVEUI
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowModel = MainWindowModel()

    var body: some View {
        ZStack {
            Group {
                switch windowModel.selectedTab {
                case .pictures:
                    PicturesTabView()
                case .videos:
                    VideosTabView()
                case .local:
                    LocalTabView()
                case .filters:
                    FiltersTabView()
                case .windows:
                    WindowsTabView()
                case .settings:
                    SettingsTabView()
                case .remote:
                    RemoteTabView()
                case .console:
                    ConsoleTabView()
                }
            }
            .id(windowModel.selectedTab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.25), value: windowModel.selectedTab)
        .environment(appModel)
        .environment(windowModel)
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                TabBarOrnament()
                    .environment(appModel)
                    .environment(windowModel)
            }
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        appModel.mainWindowSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        appModel.mainWindowSize = newSize
                    }
            }
        )

        .alert(
            "Window Already Open",
            isPresented: Binding(
                get: { shouldShowDuplicatePrompt },
                set: { _ in }
            )
        ) {
            Button("Summon") {
                summonDuplicatePhotoWindow()
            }
            Button("Open Copy") {
                allowDuplicatePhotoWindowOpen()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingPhotoWindowOpens()
            }
        } message: {
            Text("A window for this image is already open. You can summon it or open a copy.")
        }
        .alert(
            "Viewer Already Open",
            isPresented: Binding(
                get: { shouldShowRemoteViewerDuplicatePrompt },
                set: { _ in }
            )
        ) {
            Button("Summon") {
                summonDuplicateRemoteViewer()
            }
            Button("Open Copy") {
                allowDuplicateRemoteViewerOpen()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingRemoteViewerOpens()
            }
        } message: {
            Text("A viewer with this configuration is already open. You can summon it or open a copy.")
        }
        .onAppear {
            consumePendingGalleryFilterIfNeeded()
            handlePhotoWindowOpenIfNeeded()
            handleVideoWindowOpenIfNeeded()
            handleRemoteViewerOpenIfNeeded()
        }
        .onChange(of: appModel.activePhotoWindowOpenRequest?.id) { _, _ in
            handlePhotoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activeVideoWindowOpenRequest?.id) { _, _ in
            handleVideoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activeRemoteViewerOpenRequest?.id) { _, _ in
            handleRemoteViewerOpenIfNeeded()
        }
    }

    // MARK: - Pending Gallery Filter (tag-tapped from media info)

    /// If a tag was tapped in a media info sheet, this newly created main window
    /// adopts the seeded filter: switch to the right content tab and run the
    /// query. Consumed once so other/existing windows don't also react.
    private func consumePendingGalleryFilterIfNeeded() {
        guard let pending = appModel.pendingGalleryFilter else { return }
        appModel.pendingGalleryFilter = nil
        if pending.isVideo {
            windowModel.selectedTab = .videos
            windowModel.lastContentTab = .videos
            Task { await appModel.applyVideoFilter() }
        } else {
            windowModel.selectedTab = .pictures
            windowModel.lastContentTab = .pictures
            Task { await appModel.applyFilter() }
        }
    }

    // MARK: - Photo Window Duplicate Handling

    private var shouldShowDuplicatePrompt: Bool {
        guard let request = appModel.activePhotoWindowOpenRequest else { return false }
        return appModel.shouldConfirmDuplicateOpen(for: request)
    }

    private func handlePhotoWindowOpenIfNeeded() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        guard !appModel.shouldConfirmDuplicateOpen(for: request) else { return }

        // Same visionOS 27 parked-scene hazard as the remote viewer (see
        // handleRemoteViewerOpenIfNeeded): dismiss the parked scene and open a
        // fresh window instead of recalling the same value.
        if case .backgroundedInOtherRoom = appModel.existingWindowState(for: request.image.fullSizeURL) {
            for value in appModel.popOutWindowValues(for: request.image.fullSizeURL) {
                dismissWindow(id: "photo-detail", value: value)
            }
        }

        appModel.advancePhotoWindowOpenQueue()
        var value = PhotoWindowValue(image: request.image)
        // Group restores carry the geometry the window was saved at; the display
        // view applies it on appear.
        value.restoredSize = request.restoredSize.map(RAVECodableSize.init)
        openWindow(id: "photo-detail", value: value)
    }

    // MARK: - Video Window Opens

    /// Video windows have no duplicate-summon dialog; the queue only exists so
    /// AppModel can hand a fully-built window value to a view that owns an
    /// `openWindow` action (window-group restores).
    private func handleVideoWindowOpenIfNeeded() {
        guard let request = appModel.activeVideoWindowOpenRequest else { return }
        appModel.advanceVideoWindowOpenQueue()
        openWindow(id: "video-detail", value: request.windowValue)
    }

    private func summonDuplicatePhotoWindow() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        let existingValues = appModel.popOutWindowValues(for: request.image.fullSizeURL)
        if let existingValue = existingValues.first {
            openWindow(id: "photo-detail", value: existingValue)
        }
        appModel.advancePhotoWindowOpenQueue()
    }

    private func allowDuplicatePhotoWindowOpen() {
        appModel.confirmDuplicateOpen()
        handlePhotoWindowOpenIfNeeded()
    }

    // MARK: - Remote Viewer Duplicate Handling

    private var shouldShowRemoteViewerDuplicatePrompt: Bool {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return false }
        return appModel.shouldConfirmDuplicateRemoteViewerOpen(for: request)
    }

    private func handleRemoteViewerOpenIfNeeded() {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return }
        guard !appModel.shouldConfirmDuplicateRemoteViewerOpen(for: request) else { return }

        // Never recall a scene parked in another room by re-opening its value:
        // visionOS 27's room persistence can activate the parked scene without
        // ever re-attaching it to a placement, leaving the window permanently
        // invisible and non-interactable (reproduces with the stock Clock app;
        // see internal_docs/visionos27-invisible-window-feedback.md). Destroy
        // the parked scene and open a fresh one at the user instead —
        // re-opening alone never re-placed the window anyway (see
        // WindowGroupRestoreSheet.summonExistingWindow).
        if case .backgroundedInOtherRoom = appModel.existingRemoteViewerWindowState(for: request.configId) {
            for value in appModel.remoteViewerWindowValues(for: request.configId) {
                dismissWindow(id: "remote-viewer", value: value)
            }
        }

        appModel.advanceRemoteViewerOpenQueue()
        var value = RemoteViewerWindowValue(configId: request.configId)
        value.restoredSize = request.restoredSize.map(RAVECodableSize.init)
        openWindow(id: "remote-viewer", value: value)
    }

    private func summonDuplicateRemoteViewer() {
        guard let request = appModel.activeRemoteViewerOpenRequest else { return }
        let existingValues = appModel.remoteViewerWindowValues(for: request.configId)
        if let existingValue = existingValues.first {
            openWindow(id: "remote-viewer", value: existingValue)
        }
        appModel.advanceRemoteViewerOpenQueue()
    }

    private func allowDuplicateRemoteViewerOpen() {
        appModel.confirmDuplicateRemoteViewerOpen()
        handleRemoteViewerOpenIfNeeded()
    }
}
