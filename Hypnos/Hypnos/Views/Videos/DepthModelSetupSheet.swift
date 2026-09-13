/*
 Hypnos - Depth Model Setup Sheet

 First-run onboarding for real-time fake-3D video. Fake-3D needs a Core ML
 monocular depth model to estimate 3D structure from each frame — there is no
 heuristic fallback — so this sheet is presented the first time the user taps
 "Convert to 3D" with no model installed.

 The variant list, the download and the progress live in `RAVEMedia` as
 `RAVEDepthModelSetupView`, shared with Raven. What stays here is what the
 choice *means* to this app: a first model becomes the pick for both roles, and
 the note about pushing your own points at this repo's scripts.

 Once any model is installed this sheet no longer appears; switching/downloading
 happens through the ViewMode "Depth Model" submenu and Settings.
 */

import RAVEMedia
import SwiftUI

struct DepthModelSetupSheet: View {
    @Environment(AppModel.self) private var appModel

    /// Called once a model is installed + selected, to engage fake-3D.
    var onModelReady: () -> Void

    var body: some View {
        RAVEDepthModelSetupView(
            prompt: "Convert this video to 3D in real time. Pick a depth model to download — it estimates 3D structure from each frame. Bigger models look better; smaller ones are quicker and lighter. You only need to do this once."
        ) { variant in
            // First model on the device — make it the pick for both roles.
            appModel.realtimeDepthModelName = variant.name
            appModel.preprocessDepthModelName = variant.name
            onModelReady()
        } footer: {
            Label {
                Text("Advanced: you can also use your own Core ML depth model — push it with `scripts/push-depth-model.sh` or drop it into the app's Documents folder, and it'll appear here after a relaunch.")
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}
