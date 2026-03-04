/*
 Spatial Stash - Content View

 Root view with tab-based content switching and ornament navigation.
 */

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch appModel.selectedTab {
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
            }
        }
        .environment(appModel)
        .ornament(
            visibility: shouldShowOrnament ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                if appModel.selectedTab == .videos && appModel.isShowingVideoDetail {
                    // Show video player controls
                    VideoOrnamentsView(videoCount: appModel.galleryVideos.count)
                } else {
                    // Show tab bar for all tabs
                    TabBarOrnament()
                }
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
        .ornament(
            visibility: shouldShowRestoreButton ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                Button {
                    appModel.toggleUIVisibility()
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .glassBackgroundEffect()
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
            Button("Open New") {
                allowDuplicatePhotoWindowOpen()
            }
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingPhotoWindowOpens()
            }
        } message: {
            Text("A window for this image is already open. You can summon it to your current position or open another window.")
        }
        .onAppear {
            handlePhotoWindowOpenIfNeeded()
        }
        .onChange(of: appModel.activePhotoWindowOpenRequest?.id) { _, _ in
            handlePhotoWindowOpenIfNeeded()
        }
    }

    private var shouldShowOrnament: Bool {
        // Hide ornament when picture viewer is active (it has its own ornament)
        if appModel.isPictureViewerActive {
            return false
        }
        // Hide ornament when user has hidden UI in video detail view
        if appModel.isShowingVideoDetail && appModel.isUIHidden {
            return false
        }
        return true
    }

    private var shouldShowRestoreButton: Bool {
        // Show restore button only when UI is hidden in video detail view
        // (picture viewer uses tap-to-unhide instead)
        appModel.isShowingVideoDetail && appModel.isUIHidden
    }

    private var shouldShowDuplicatePrompt: Bool {
        guard let request = appModel.activePhotoWindowOpenRequest else { return false }
        return appModel.shouldConfirmDuplicateOpen(for: request)
    }

    private func handlePhotoWindowOpenIfNeeded() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        guard !appModel.shouldConfirmDuplicateOpen(for: request) else { return }
        openWindow(id: "photo-detail", value: PhotoWindowValue(image: request.image))
        appModel.advancePhotoWindowOpenQueue()
    }

    private func summonDuplicatePhotoWindow() {
        guard let request = appModel.activePhotoWindowOpenRequest else { return }
        let existingValues = appModel.popOutWindowValues(for: request.image.fullSizeURL)
        for value in existingValues {
            dismissWindow(id: "photo-detail", value: value)
        }
        openWindow(id: "photo-detail", value: PhotoWindowValue(image: request.image))
        appModel.advancePhotoWindowOpenQueue()
    }

    private func allowDuplicatePhotoWindowOpen() {
        appModel.confirmDuplicateOpen()
        handlePhotoWindowOpenIfNeeded()
    }
}
