/*
 Spatial Stash - Depth Model Setup Sheet

 First-run onboarding for real-time fake-3D video. Fake-3D needs a Core ML
 monocular depth model to estimate 3D structure from each frame — there is no
 heuristic fallback — so this sheet is presented the first time the user taps
 "Convert to 3D" with no model installed. It explains the offered variants
 (quality vs. size/speed), downloads the chosen one straight from Apple's
 Hugging Face repo, and on success selects it and engages fake-3D.

 Once any model is installed this sheet no longer appears; switching/downloading
 happens through the ViewMode "Depth Model" submenu and Settings.
 */

import RAVEMedia
import SwiftUI

struct DepthModelSetupSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var depthModels = DepthModelManager.shared

    /// Called once a model is installed + selected, to engage fake-3D.
    var onModelReady: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Convert this video to 3D in real time. Pick a depth model to download — it estimates 3D structure from each frame. Bigger models look better; smaller ones are quicker and lighter. You only need to do this once.")
                        .foregroundStyle(.secondary)

                    ForEach(DepthModelManager.variants) { variant in
                        modelRow(variant)
                    }

                    if let error = depthModels.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Label {
                        Text("Advanced: you can also use your own Core ML depth model — push it with `scripts/push-depth-model.sh` or drop it into the app's Documents folder, and it'll appear here after a relaunch.")
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(24)
            }
            .navigationTitle("Add a 3D Depth Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
    }

    @ViewBuilder
    private func modelRow(_ variant: DepthModelManager.Variant) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variant.displayName)
                    .font(.headline)
                Text(variant.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if depthModels.isDownloading(variant) {
                ProgressView(value: depthModels.progress[variant.name] ?? 0)
                    .frame(width: 120)
            } else if depthModels.isInstalled(variant) {
                Button("Use") { selectAndFinish(variant) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task {
                        await depthModels.download(variant)
                        if depthModels.isInstalled(variant) { selectAndFinish(variant) }
                    }
                } label: {
                    Label(byteLabel(variant.approxBytes), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectAndFinish(_ variant: DepthModelManager.Variant) {
        // First model on the device — make it the pick for both roles.
        appModel.realtimeDepthModelName = variant.name
        appModel.preprocessDepthModelName = variant.name
        onModelReady()
        dismiss()
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
