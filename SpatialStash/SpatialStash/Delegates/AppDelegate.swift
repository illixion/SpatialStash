/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the application.
*/

import SwiftUI

@Observable
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
