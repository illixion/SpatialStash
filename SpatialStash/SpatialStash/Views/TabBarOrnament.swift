/*
 Spatial Stash - Tab Bar Ornament

 visionOS ornament-based tab navigation for Pictures, Videos, and Settings.
 */

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
        HStack(spacing: 8) {
            ForEach(visibleTabs) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: windowModel.selectedTab == tab,
                    action: { select(tab) }
                )
            }

            // Slideshow of what's on screen. Separated from the tabs because it
            // acts on the current tab rather than navigating, and only present
            // on the tabs that show media.
            if let launch = slideshowLaunch {
                Divider()
                    .frame(height: 28)
                    .padding(.horizontal, 4)
                SlideshowLaunchButton(help: launch.help, action: launch.start)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        // Sit below the window's bottom edge so a protruding diorama
        // foreground layer doesn't visually clip the tab bar.
        .padding(.top, 20)
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

private struct SlideshowLaunchButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(TabBarButtonStyle(isSelected: false))
        .hoverEffect(.highlight)
        .help(help)
    }
}

private struct TabBarButton: View {
    let tab: Tab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.title3)
                if isSelected {
                    Text(tab.rawValue)
                        .font(.callout)
                        .fontWeight(.medium)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, isSelected ? 14 : 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(TabBarButtonStyle(isSelected: isSelected))
        .hoverEffect(.highlight)
        .help(tab.rawValue)
        .animation(.smooth(duration: 0.22), value: isSelected)
    }
}

private struct TabBarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .primary : .secondary)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        )
                }
            }
    }
}
