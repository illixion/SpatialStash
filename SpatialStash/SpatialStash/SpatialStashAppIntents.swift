/*
 Spatial Stash - App Intents surface

 The intent itself (RAVEOpenMainWindowIntent) lives in RAVEUI so every RAVE app
 ships the same behavior; only the pieces that cannot live in a package are
 here — the AppIntentsPackage chain that lets Xcode's metadata extractor see
 the package's intents, and the App Shortcuts (Siri phrases), which must be
 defined in the app target.

 Why this exists: visionOS gives apps no say over which scene an icon tap
 foregrounds — with any window parked in another room, the OS summons it to
 the user instead of opening a main window. "Hey Siri, open a Spatial Stash
 window" is the supported way to always get a main window at your location.
 */

import AppIntents
import RAVEUI

// A standalone conformer, not an extension on SpatialStashApp: the App
// protocol is MainActor-isolated and cannot satisfy this nonisolated protocol
// under Swift 6.
struct SpatialStashAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [RAVEUIAppIntentsPackage.self]
    }
}

struct SpatialStashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RAVEOpenMainWindowIntent(),
            phrases: [
                "Open a \(.applicationName) window",
                "Open a new \(.applicationName) window",
                "Open the main \(.applicationName) window",
                "Summon \(.applicationName)"
            ],
            shortTitle: "Open Main Window",
            systemImageName: "macwindow.badge.plus"
        )
    }
}
