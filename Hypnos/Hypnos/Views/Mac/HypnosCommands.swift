/*
 Hypnos - macOS menu bar commands

 The `.commands` this app's macOS scene attaches to the main-window
 `WindowGroup`. `View → <tab>` and the Play/Pause space go through
 `NotificationCenter` rather than a shared `@State` selection, because
 `.commands` closures have no access to a specific window's view state (they
 belong to the app, not one scene instance) — the same reason macOS apps
 generally route menu actions to whichever window is key via notifications or
 first-responder `@objc` actions. Every `MacRootView`/`MacVideoPlayerWindow`
 instance listens and only the one that matters (key window in practice) acts
 on it; with more than one main or video window open, all of them do, which is
 an acceptable simplification for a first pass (see `Hypnos/CLAUDE.md`
 "macOS").
 */

#if os(macOS)

import SwiftUI

extension Notification.Name {
    static let hypnosSelectTab = Notification.Name("Hypnos.selectTab")
    static let hypnosTogglePlayPause = Notification.Name("Hypnos.togglePlayPause")
}

struct HypnosCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Library") {
            ForEach(MacTab.allCases) { tab in
                Button(tab.rawValue) {
                    NotificationCenter.default.post(name: .hypnosSelectTab, object: tab)
                }
            }

            Divider()

            Button("Play/Pause") {
                NotificationCenter.default.post(name: .hypnosTogglePlayPause, object: nil)
            }
            .keyboardShortcut(.space, modifiers: [])
        }
    }
}

#endif
