/*
 Hypnos - tvOS root

 The Apple TV app's single scene root (see `HypnosApp`). A plain SwiftUI
 `TabView` on tvOS already renders as the platform's top tab bar — no
 ornament, no custom chrome needed to get that shape, unlike visionOS/iOS.

 Deliberately not a port of `ContentView`: that view's tabs, ornament and
 gestures are all touch/gaze-shaped (see `Hypnos/CLAUDE.md` "tvOS" for what's
 excluded and why). This is a fresh, small root built for a Siri Remote:
 five tabs (Pictures, Videos, Albums, Films, Settings), no developer tabs,
 no Windows tab (nothing to summon — tvOS has one scene), no Filters tab
 (nothing there to filter by yet on a remote-driven grid).
 */

#if os(tvOS)

import SwiftUI

struct TVRootView: View {
    let appModel: AppModel
    @State private var selectedTab: TVTab = .pictures

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(TVTab.allCases) { tab in
                tabContent(tab)
                    .tag(tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                    }
            }
        }
        .environment(appModel)
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TVTab) -> some View {
        switch tab {
        case .pictures:
            TVPicturesTabView()
        case .videos:
            TVVideosTabView()
        case .albums:
            TVAlbumsTabView(selectedTab: $selectedTab)
        case .films:
            TVFilmsTabView()
        case .settings:
            TVSettingsView()
        }
    }
}

#endif
