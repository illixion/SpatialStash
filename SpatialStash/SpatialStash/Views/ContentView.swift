/*
 Spatial Stash - Content View

 Root view with tab-based content switching and ornament navigation.
 */

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowModel = MainWindowModel()

    var body: some View {
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
            case .settings:
                SettingsTabView()
            case .remote:
                RemoteTabView()
            case .console:
                DebugConsoleView()
            }
        }
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
            handlePhotoWindowOpenIfNeeded()
            handleRemoteViewerOpenIfNeeded()
        }
        .onChange(of: appModel.activePhotoWindowOpenRequest?.id) { _, _ in
            handlePhotoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activeRemoteViewerOpenRequest?.id) { _, _ in
            handleRemoteViewerOpenIfNeeded()
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

        if case .backgroundedInOtherRoom(let existingValue) = appModel.existingWindowState(for: request.image.fullSizeURL) {
            appModel.advancePhotoWindowOpenQueue()
            openWindow(id: "photo-detail", value: existingValue)
            return
        }

        appModel.advancePhotoWindowOpenQueue()
        openWindow(id: "photo-detail", value: PhotoWindowValue(image: request.image))
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

        if case .backgroundedInOtherRoom(let existingValue) = appModel.existingRemoteViewerWindowState(for: request.configId) {
            appModel.advanceRemoteViewerOpenQueue()
            openWindow(id: "remote-viewer", value: existingValue)
            return
        }

        appModel.advanceRemoteViewerOpenQueue()
        openWindow(id: "remote-viewer", value: RemoteViewerWindowValue(configId: request.configId))
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
