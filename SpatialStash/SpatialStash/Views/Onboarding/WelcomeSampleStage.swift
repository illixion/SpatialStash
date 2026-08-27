/*
 Spatial Stash - Welcome Sample Stage

 The first screen's centrepiece: the bundled sample photo, with a control that
 converts it to spatial 3D and then toggles between flat and 3D.

 This runs the **real** conversion — the same `Spatial3DImage.generate()` the
 photo viewer runs — rather than crossfading two pre-baked images. A canned
 before/after would be easier and would also be the one thing a first-run
 screen must not do: claim a result the app then has to reproduce. Watching the
 depth actually build, on this device, at this speed, is the honest version of
 the pitch, and it doubles as a check that the pipeline works before the user
 has pointed the app at anything of their own.

 Toggling back to flat afterwards costs nothing (`desiredViewingMode` on the
 already-generated component), so the control becomes a two-way switch rather
 than a one-shot button — the point being that 3D is a way of looking at a
 photo, not a conversion that consumes it.
 */

import os
import RealityKit
import SwiftUI

@MainActor
@Observable
final class WelcomeSampleModel {

    enum Stage: Equatable {
        /// Nothing attempted yet.
        case idle
        /// Decoding the sample into a `Spatial3DImage`.
        case preparing
        /// Flat, ready to convert.
        case flat
        /// `generate()` in flight.
        case converting
        /// Generated; the control is now a 2D/3D switch.
        case ready
        /// No sample bundled, or it could not be decoded.
        case unavailable
    }

    private(set) var stage: Stage = .idle
    /// Which way the switch is thrown once `stage == .ready`.
    var showing3D = true
    private(set) var aspectRatio: CGFloat = 3.0 / 2.0

    let entity = Entity()
    private var spatial3DImage: ImagePresentationComponent.Spatial3DImage?

    var isBusy: Bool { stage == .preparing || stage == .converting }

    /// Decodes the sample and attaches a flat presentation component.
    func prepare() async {
        guard stage == .idle else { return }
        guard let url = WelcomeSample.url() else {
            stage = .unavailable
            return
        }
        stage = .preparing
        do {
            let image = try await ImagePresentationComponent.Spatial3DImage(contentsOf: url)
            var component = ImagePresentationComponent(spatial3DImage: image)
            component.desiredViewingMode = .mono
            entity.components.set(component)
            if let ratio = component.aspectRatio(for: .mono) {
                aspectRatio = CGFloat(ratio)
            }
            spatial3DImage = image
            stage = .flat
        } catch {
            AppLogger.settings.error("Welcome sample could not be decoded: \(error.localizedDescription, privacy: .public)")
            stage = .unavailable
        }
    }

    /// Generates the depth scene, then leaves the switch on 3D.
    ///
    /// `desiredViewingMode` is set *before* generating, which is what gives the
    /// build-in animation something to animate into — the same ordering the
    /// photo viewer uses.
    func convert() async {
        guard stage == .flat, let spatial3DImage else { return }
        guard var component = entity.components[ImagePresentationComponent.self] else { return }

        component.desiredViewingMode = .spatial3D
        entity.components.set(component)
        stage = .converting

        do {
            try await spatial3DImage.generate()
            if let ratio = component.aspectRatio(for: .spatial3D) {
                aspectRatio = CGFloat(ratio)
            }
            showing3D = true
            stage = .ready
        } catch {
            AppLogger.settings.error("Welcome sample conversion failed: \(error.localizedDescription, privacy: .public)")
            // Back to flat rather than to an error state: the sample is a demo,
            // and a failed demo should still show the photo.
            component.desiredViewingMode = .mono
            entity.components.set(component)
            stage = .flat
        }
    }

    /// Applies the switch position to the live component.
    func applyViewingMode() {
        guard stage == .ready else { return }
        guard var component = entity.components[ImagePresentationComponent.self] else { return }
        let mode: ImagePresentationComponent.ViewingMode = showing3D ? .spatial3D : .mono
        guard component.viewingMode != mode else { return }
        component.desiredViewingMode = mode
        entity.components.set(component)
        if let ratio = component.aspectRatio(for: mode) {
            aspectRatio = CGFloat(ratio)
        }
    }

    /// Scales the presentation to fill the space the view gave it, in meters.
    func fit(in boundsInMeters: BoundingBox) {
        guard let component = entity.components[ImagePresentationComponent.self] else { return }
        let screen = component.presentationScreenSize
        guard screen.x > 0, screen.y > 0 else { return }
        let scale = min(boundsInMeters.extents.x / screen.x,
                        boundsInMeters.extents.y / screen.y)
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }
}

struct WelcomeSampleStage: View {
    @State private var model = WelcomeSampleModel()

    var body: some View {
        VStack(spacing: 22) {
            // Availability is decided from the bundle, synchronously, rather
            // than from `stage`: the RealityView has to exist before `prepare()`
            // can run inside it, so a stage-driven branch would never mount it.
            if WelcomeSample.isAvailable {
                stage
            } else {
                MissingSampleCard()
            }
            control
                .animation(.smooth(duration: 0.25), value: model.stage)
        }
    }

    private var stage: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                // In the make closure rather than a `.task`, matching the photo
                // viewer: the entity must carry its component before anything
                // tries to scale it, and a task runs a frame too late.
                await model.prepare()
                if model.entity.parent == nil {
                    content.add(model.entity)
                }
                model.fit(in: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            } update: { content in
                model.fit(in: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            }
            .overlay {
                switch model.stage {
                case .idle, .preparing:
                    ProgressView()
                case .unavailable:
                    MissingSampleCard()
                default:
                    EmptyView()
                }
            }
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)
    }

    @ViewBuilder
    private var control: some View {
        switch model.stage {
        case .idle, .preparing:
            Text("Preparing sample…")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .flat:
            Button {
                Task { await model.convert() }
            } label: {
                Label("Convert to 3D", systemImage: "cube.transparent")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .converting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Building depth…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            VStack(spacing: 10) {
                Picker("Viewing mode", selection: Binding(
                    get: { model.showing3D },
                    set: { model.showing3D = $0; model.applyViewingMode() }
                )) {
                    Text("Flat").tag(false)
                    Text("Spatial 3D").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .labelsHidden()

                Text("Lean in — the depth is real, not a parallax trick.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .unavailable:
            EmptyView()
        }
    }
}

/// Shown in place of the photo when no sample is bundled, so the flow still
/// reads as intentional rather than broken.
private struct MissingSampleCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Any flat photo becomes a window you can look into.")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("Point the app at your library on the next screen and try it on one of your own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }
}
