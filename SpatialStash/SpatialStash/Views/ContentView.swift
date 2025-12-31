/*
 Spatial Stash - Content View

 Root view with tab-based content switching and ornament navigation.
 */

import RealityKit
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
                if appModel.selectedTab == .pictures && appModel.isShowingDetailView {
                    // Show detail view controls when viewing an image
                    OrnamentsView(imageCount: appModel.galleryImages.count)
                } else if appModel.selectedTab == .videos && appModel.isShowingVideoDetail {
                    // Show video player controls
                    VideoOrnamentsView(videoCount: appModel.galleryVideos.count)
                } else {
                    // Show tab bar for all tabs (Pictures gallery, Videos, Settings)
                    TabBarOrnament()
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
        // Hide ornament during 3D generation animation
        if appModel.spatial3DImageState == .generating {
            return false
        }
        // Hide ornament when user has hidden UI in detail view
        if appModel.isShowingDetailView && appModel.isUIHidden {
            return false
        }
        return true
    }

    private var shouldShowRestoreButton: Bool {
        // Show restore button only when UI is hidden in detail view
        appModel.isShowingDetailView && appModel.isUIHidden && !appModel.isLoadingDetailImage
    }
}
