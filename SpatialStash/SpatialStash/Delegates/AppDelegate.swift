/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the application.
*/

import os
import SwiftUI

@Observable
class AppDelegate: NSObject, UIApplicationDelegate {
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
