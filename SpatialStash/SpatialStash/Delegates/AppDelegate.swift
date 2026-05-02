/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the application.
*/

import os
import SwiftUI

@Observable
class AppDelegate: NSObject, UIApplicationDelegate {
    /// Tracks whether we've already handled the initial activation so a
    /// gaze-suspended app resuming on look-back doesn't re-summon the main
    /// window.
    private var didHandleInitialActivation = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Trigger the LAN access permission prompt early so the user sees it
        // before the app tries to connect to the Stash server.
        triggerLocalNetworkAccessPrompt()

        // Ensure local media directories exist so the app shows up in Files app
        Task {
            await LocalMediaSource.shared.ensureDirectoriesExist()
        }
        // Clean up orphaned shared media cache entries from previous sessions
        Task {
            await SharedMediaCache.shared.cleanupOrphanedEntries()
        }
        return true
    }

    /// Fires once per process lifetime on the first `didBecomeActive`. If the
    /// only restored scenes are pop-outs (main window was previously closed),
    /// summon a main window so the user has a way to navigate the app.
    /// Subsequent activations — including gaze-resume after visionOS suspends
    /// the process — are ignored, which prevents the main window from popping
    /// up unexpectedly when the user merely looks back at a wall-pinned window.
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !didHandleInitialActivation else { return }
        didHandleInitialActivation = true
        Task { @MainActor in
            // Give SwiftUI a moment to attach restored scenes and run their
            // onAppear so `mainWindowCount` reflects reality.
            try? await Task.sleep(for: .milliseconds(400))
            WindowSessionRegistry.shared.ensureMainWindowVisible()
        }
    }

    /// Accesses `ProcessInfo.processInfo.hostName` to trigger the local network
    /// access permission dialog. The result is discarded — the sole purpose is
    /// to surface the system prompt as early as possible.
    private func triggerLocalNetworkAccessPrompt() {
        let hostName = ProcessInfo.processInfo.hostName
        AppLogger.app.info("Local network access check completed (host: \(hostName, privacy: .private))")
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}
