/*
 Spatial Stash - Content View

 Root view with tab-based content switching and ornament navigation.
 */

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.selectedTab {
            case .pictures:
                PicturesTabView()
            case .videos:
                VideosTabView()
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
    }

    private var shouldShowOrnament: Bool {
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
}
