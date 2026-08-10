/*
 Spatial Stash - Tab Bar Ornament

 visionOS ornament-based tab navigation for Pictures, Videos, and Settings.
 */

import RAVEUI
import SwiftUI

struct TabBarOrnament: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel

    private var visibleTabs: [Tab] {
        let orderedTabs: [Tab] = [.pictures, .videos, .local, .remote, .filters, .console, .settings]
        return orderedTabs.filter { tab in
            switch tab {
            case .remote:
                return appModel.enableRemoteViewer
            case .console:
                return appModel.showDebugConsole
            default:
                return true
            }
        }
    }

    var body: some View {
        @Bindable var windowModel = windowModel
        RAVETabBar(
            tabs: visibleTabs,
            selection: $windowModel.selectedTab,
            // Routed through `select` rather than straight to the binding:
            // re-tapping Local is a "pop to the folder root" gesture, which a
            // plain selection binding cannot see.
            onSelect: select
        ) {
            // Slideshow of what's on screen. Separated from the tabs because it
            // acts on the current tab rather than navigating, and only present
            // on the tabs that show media.
            if let launch = slideshowLaunch {
                RAVETabBarDivider()
                RAVETabBarActionButton(
                    systemImage: "play.fill",
                    help: launch.help,
                    action: launch.start
                )
            }
        }
        .animation(.smooth(duration: 0.22), value: slideshowLaunch?.help)
    }

    /// What the play button would start, or nil when the current tab isn't
    /// showing anything a slideshow could run over.
    private var slideshowLaunch: (help: String, start: () -> Void)? {
        switch windowModel.selectedTab {
        case .pictures:
            // Nothing loaded yet — a slideshow would open on an empty source.
            guard !appModel.galleryImages.isEmpty else { return nil }
            return ("Slideshow of these pictures", {
                appModel.startGallerySlideshow(
                    imageSource: appModel.imageSource,
                    filter: appModel.currentFilter
                )
            })
        case .videos:
            guard !appModel.galleryVideos.isEmpty else { return nil }
            return ("Slideshow of these videos", {
                appModel.startVideoSlideshow(
                    videoSource: appModel.videoSource,
                    filter: appModel.currentVideoFilter
                )
            })
        case .local:
            // The root level is a folder picker — there's no "this folder" yet.
            guard let folder = LocalFolderSlideshowTarget(path: windowModel.localFolderPath) else {
                return nil
            }
            return (folder.help, { folder.start(appModel: appModel) })
        case .filters, .settings, .remote, .console:
            return nil
        }
    }

    private func select(_ tab: Tab) {
        if tab == .pictures || tab == .videos {
            windowModel.lastContentTab = tab
        }
        if tab == .local && windowModel.selectedTab == .local {
            windowModel.localTabReselected += 1
        } else {
            windowModel.selectedTab = tab
        }
    }
}

/// Which local folder the Local tab is on, and what a slideshow of it means.
/// The Photos and Videos trees need different sources, and a folder-scoped
/// source in both cases so the slideshow matches the folder on screen.
@MainActor
private struct LocalFolderSlideshowTarget {
    let path: [String]
    let isVideos: Bool

    init?(path: [String]) {
        guard let root = path.first else { return nil }
        self.path = path
        self.isVideos = root == LocalTabView.LocalMediaFolder.videos.rawValue
    }

    var help: String {
        "Slideshow of \(path.last ?? "this folder")"
    }

    private var folderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return path.reduce(documents) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    func start(appModel: AppModel) {
        if isVideos {
            appModel.startVideoSlideshow(videoSource: LocalVideoSource(rootURL: folderURL), filter: nil)
        } else {
            appModel.startGallerySlideshow(imageSource: LocalImageSource(rootURL: folderURL), filter: nil)
        }
    }
}
