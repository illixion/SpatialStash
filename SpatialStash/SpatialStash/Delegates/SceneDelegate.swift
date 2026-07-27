/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate class for the scene.
*/

import os
import SwiftUI

@Observable class SceneDelegate: NSObject, UIWindowSceneDelegate {
    weak var windowScene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            AppLogger.views.warning("Unable to get the window scene in the Scene Delegate")
            return
        }
        self.windowScene = windowScene

        // Share-sheet cold launch: when Files.app opens us with a file
        // selected, the URL arrives here, not via SwiftUI's .onOpenURL on
        // an already-running scene. Forward it through the same
        // notification pipeline used for warm shares.
        if !connectionOptions.urlContexts.isEmpty {
            SceneDelegate.deliverSharedURLs(connectionOptions.urlContexts.map { $0.url })
        }
    }

    /// Warm-share path: Files.app sending a file while the app is already
    /// running. With a custom UIWindowSceneDelegate, SwiftUI's `.onOpenURL`
    /// doesn't fire unless we explicitly forward the context.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegate.deliverSharedURLs(URLContexts.map { $0.url })
    }

    /// Broadcast notification consumed by every mounted `IncomingURLHandler`.
    /// Posted on the main queue so SwiftUI observers receive it on the main actor.
    static let sharedURLNotification = Notification.Name("SpatialStash.sharedURLReceived")

    /// Cold-launch backlog. `scene(_:willConnectTo:)` runs *before* any SwiftUI
    /// scene root has mounted its `.onReceive`, so a share that launches the app
    /// posts into the void — the notification is fire-and-forget and nothing
    /// replays it. Every delivered URL is therefore also parked here and drained
    /// by the first handler to appear (`drainPendingURLs`), which is what makes
    /// "share a file into the not-running app" work at all. Warm shares hit a
    /// live observer first and `consumePending` removes them from the backlog so
    /// a later-mounting window can't reopen them.
    private static let pendingLock = NSLock()
    private static var pendingURLs: [URL] = []

    /// Take (and clear) any URLs delivered before a handler was listening.
    static func drainPendingURLs() -> [URL] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }

    /// Drop a URL from the backlog once a live handler has taken ownership of it.
    static func consumePending(_ url: URL) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingURLs.removeAll { $0 == url }
    }

    private static func deliverSharedURLs(_ urls: [URL]) {
        pendingLock.lock()
        pendingURLs.append(contentsOf: urls)
        pendingLock.unlock()

        for url in urls {
            AppLogger.sharedMedia.info("SceneDelegate received shared URL: \(url.lastPathComponent, privacy: .public)")
            NotificationCenter.default.post(name: sharedURLNotification, object: url)
        }
    }
}
