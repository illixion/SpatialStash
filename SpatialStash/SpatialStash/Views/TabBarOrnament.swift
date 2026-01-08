/*
 Spatial Stash - Tab Bar Ornament

 visionOS ornament-based tab navigation for Pictures, Videos, and Settings.
 */

import SwiftUI

struct TabBarOrnament: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases) { tab in
                Button {
                    // Track last content tab for filter context
                    if tab == .pictures || tab == .videos {
                        appModel.lastContentTab = tab
                    }
                    appModel.selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.title2)
                        Text(tab.rawValue)
                            .font(.caption)
                    }
                    .foregroundColor(appModel.selectedTab == tab ? .white : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        appModel.selectedTab == tab
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .glassBackgroundEffect()
    }
}
