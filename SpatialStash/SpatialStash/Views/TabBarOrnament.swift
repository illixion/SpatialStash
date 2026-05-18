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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        // Sit below the window's bottom edge so a protruding diorama
        // foreground layer doesn't visually clip the tab bar.
        .padding(.top, 20)
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
