/*
 Spatial Stash - Windows Tab

 Inventory of every open window, with Summon and Close on each. The list, the
 rows and the recycle mechanics are RAVEUI's `RAVEWindowManagerView`; this adds
 the app's bulk controls underneath it.

 Summon exists for two reasons: fetching a window snapped in another room, and
 recovering one lost to the visionOS 27 placement bug, where a scene stays
 active and "visible" but is never drawn again (see
 internal_docs/visionos27-invisible-window-feedback.md). Both are fixed the same
 way — destroy the scene, open a fresh one at the user.
 */

import os
import RAVEUI
import SwiftUI

struct WindowsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    var body: some View {
        RAVEWindowManagerView(
            emptyMessage: "Photo, video, slideshow and tool windows you open will be listed here, so you can bring them back to you or close them."
        ) {
            Section {
                Button(appModel.allWindowsHidden ? "Unhide All Windows" : "Hide All Windows") {
                    appModel.allWindowsHidden.toggle()
                }
                .disabled(!hasSecondaryWindows && !appModel.allWindowsHidden)

                Button("Close All Windows", role: .destructive) {
                    let closed = RAVEWindowScenes.destroyAll(except: sceneDelegate?.windowScene?.session)
                    appModel.allWindowsHidden = false
                    AppLogger.settings.info("Closed \(closed, privacy: .public) secondary windows")
                }
                .disabled(!hasSecondaryWindows)
            } footer: {
                Text("Close All destroys every window scene except this one — including any the app could not list above, which is how a window left blank at launch is cleared.")
            }
        }
    }

    /// Scene-level rather than registry-level on purpose: a window that never
    /// got a layout pass never registered, and those are exactly the ones the
    /// bulk controls need to reach.
    private var hasSecondaryWindows: Bool {
        RAVEWindowScenes.hasWindows(besides: sceneDelegate?.windowScene?.session)
    }
}
