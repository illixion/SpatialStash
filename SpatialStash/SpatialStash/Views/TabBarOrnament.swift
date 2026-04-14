/*
 Spatial Stash - Tab Bar Ornament

 visionOS ornament-based tab navigation for Pictures, Videos, and Settings.
 */

import SwiftUI

struct TabBarOrnament: View {
    @Environment(AppModel.self) private var appModel

    private var visibleTabs: [Tab] {
        let orderedTabs: [Tab] = [.pictures, .videos, .local, .remote, .filters, .settings, .console]
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
        HStack(spacing: 24) {
            ForEach(visibleTabs) { tab in
                Button {
                    // Track last content tab for filter context
                    if tab == .pictures || tab == .videos {
                        appModel.lastContentTab = tab
                    }
                    
                    // Special handling for Local tab re-selection
                    if tab == .local && appModel.selectedTab == .local {
                        appModel.localTabReselected += 1
                    } else {
                        appModel.selectedTab = tab
                    }
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
