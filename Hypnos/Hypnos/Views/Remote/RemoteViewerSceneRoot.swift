/*
 Hypnos - Remote Viewer Scene Root

 Picks which window the "remote-viewer" scene builds for a given window value:
 the RoboFrame/gallery slideshow, or a pinned web page.

 Both modes share the scene (and therefore AppModel's open-window registry, the
 duplicate-open summon path, and the size write-back binding) because they're
 both launched from a RemoteViewerConfig — the mode is a property of the profile,
 not a different kind of window.
 */

import SwiftUI

struct RemoteViewerSceneRoot: View {
    let windowValue: RemoteViewerWindowValue
    let appModel: AppModel
    var onSizeSettled: ((CGSize) -> Void)? = nil

    var body: some View {
        // Resolved per body evaluation rather than cached: the profile list is
        // loaded in AppModel.init, so it's already populated even when visionOS
        // restores this scene during cold launch.
        #if canImport(WebKit)
        if appModel.remoteViewerConfig(id: windowValue.configId)?.mode == .webPage {
            WebPageWindowView(windowValue: windowValue, onSizeSettled: onSizeSettled)
        } else {
            RemoteViewerWindowView(windowValue: windowValue, onSizeSettled: onSizeSettled)
        }
        #else
        // No WebKit on tvOS, so the pinned-web-page mode has no window to
        // build. Not reachable in practice: the Remote tab (developer-only)
        // is hidden from the tvOS root UI, so nothing on TV can create a
        // `.webPage` profile in the first place.
        RemoteViewerWindowView(windowValue: windowValue, onSizeSettled: onSizeSettled)
        #endif
    }
}
