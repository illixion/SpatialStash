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
        let orderedTabs: [Tab] = [.pictures, .videos, .albums, .remote, .filters, .windows, .console, .settings]
        return orderedTabs.filter { tab in
            switch tab {
            case .remote:
                return appModel.enableRemoteViewer
            case .console:
                return appModel.showDebugConsole
            case .filters:
                // Nothing to filter by while browsing Local — no tags,
                // albums or galleries. See ContentView for the redirect if
                // this tab was already open when the library changed.
                return appModel.effectiveLibrarySource != .local
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
            // re-tapping Albums while already there is a "pop to the folder
            // root" gesture for its local-folder browser, which a plain
            // selection binding cannot see.
            onSelect: select
        ) {
            // Actions, not navigation: both act on the current tab rather than
            // moving between tabs, so they sit past a divider.
            if showsLibraryToggle || slideshowLaunch != nil {
                RAVETabBarDivider()
            }
            // Left of the slideshow button: which library the media tabs show.
            // Only meaningful with more than one source available — with
            // just Photos there is nothing to switch between.
            if showsLibraryToggle {
                let current = appModel.effectiveLibrarySource
                let next = appModel.nextLibrarySource()
                RAVETabBarActionButton(
                    systemImage: current.symbolName,
                    help: "Showing \(current.displayName) — switch to \(next.displayName)",
                    identifier: A11y.librarySwitch,
                    action: { appModel.librarySource = next }
                )
            }
            if let launch = slideshowLaunch {
                RAVETabBarActionButton(
                    systemImage: "play.fill",
                    help: launch.help,
                    action: launch.start
                )
            }
        }
        .animation(.smooth(duration: 0.22), value: slideshowLaunch?.help)
        .animation(.smooth(duration: 0.22), value: appModel.effectiveLibrarySource)
    }

    /// Whether to offer the library switch: only with more than one source
    /// available, and only on the tabs that show one.
    private var showsLibraryToggle: Bool {
        guard appModel.availableLibrarySources.count > 1 else { return false }
        switch windowModel.selectedTab {
        case .pictures, .videos: return true
        default: return false
        }
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
        // Albums is a browser: what a slideshow would run over is whatever
        // opening a container leaves on the Pictures or Videos tab, so the
        // button belongs there rather than here. That includes the Local
        // library's folder browser, which offers its own per-folder
        // "Play Slideshow" control in context instead.
        case .albums, .filters, .windows, .settings, .remote, .console:
            return nil
        }
    }

    private func select(_ tab: Tab) {
        if tab == .pictures || tab == .videos {
            windowModel.lastContentTab = tab
        }
        if tab == .albums && windowModel.selectedTab == .albums {
            windowModel.albumsReselected += 1
        } else {
            windowModel.selectedTab = tab
        }
    }
}
