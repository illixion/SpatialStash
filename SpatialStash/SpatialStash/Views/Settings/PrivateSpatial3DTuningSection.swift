//
//  PrivateSpatial3DTuningSection.swift
//  SpatialStash
//
//  Settings UI for the GitHub-only private spatial-3D tuning. Compiled out
//  unless HYPNOS_PRIVATE_API is defined.
//

#if HYPNOS_PRIVATE_API

import SwiftUI

struct PrivateSpatial3DTuningSection: View {
    @State private var store = PrivateSpatial3DTuningStore.shared

    var body: some View {
        Section("Spatial 3D Tuning (Private API)") {
            Toggle("Enable Private Tuning", isOn: Binding(
                get: { store.isEnabled },
                set: { store.isEnabled = $0; store.markChanged() }
            ))

            Text("Sets undocumented ImagePresentationComponent properties to push back on the visionOS 27 immersive spatial-3D behaviour (adaptive scene scaling and head-tracked repositioning). Private API — present in GitHub builds only, never in App Store builds. Changes apply the next time an image enters 3D or its viewing mode is switched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.isEnabled {
                #if HYPNOS_PRIVATE_API_V27
                // The one knob confirmed to fix the visionOS 27 immersive
                // change, as a single tap so it needn't be rediscovered.
                Button("Restore Pre-visionOS 27 Immersive Look") {
                    var s = store.settings
                    s.sceneRepositionMode = .restoresLegacyPresentation
                    store.settings = s
                    store.markChanged()
                }
                .disabled(store.settings.sceneRepositionMode == .restoresLegacyPresentation)

                Text("Sets Scene Reposition Mode to Align to Head Position. Cycle 3D off and on to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                // Captions record what was actually observed on device
                // (visionOS 27.0) so knobs with no effect aren't retried blind.
                floatKnob(
                    title: "Collapse Strength",
                    keyPath: \.collapseStrength,
                    stock: PrivateSpatial3DSettings.Stock.collapseStrength,
                    range: 0...1,
                    caption: "Confirmed working — flattens the spatial-3D effect. Stock is 0."
                )

                boolKnob(
                    title: "Specular & Fresnel Effects",
                    keyPath: \.specularAndFresnelEffects,
                    stock: PrivateSpatial3DSettings.Stock.specularAndFresnelEffects,
                    caption: "No visible effect observed. Stock is on."
                )

                floatKnob(
                    title: "Corner Radius (pt)",
                    keyPath: \.cornerRadiusInPoints,
                    stock: PrivateSpatial3DSettings.Stock.cornerRadiusInPoints,
                    range: 0...200,
                    caption: "No visible effect observed. Stock is 44."
                )

                #if HYPNOS_PRIVATE_API_V27
                repositionModeKnob()

                boolKnob(
                    title: "MXI Render Two-Pass",
                    keyPath: \.renderTwoPass,
                    stock: PrivateSpatial3DSettings.Stock.renderTwoPass,
                    caption: "Off makes immersive mode show the raw gaussian splat with eye reprojection tracking viewing distance. Stock is on."
                )

                boolKnob(
                    title: "User Interaction Enabled",
                    keyPath: \.userInteractionEnabled,
                    stock: PrivateSpatial3DSettings.Stock.userInteractionEnabled,
                    caption: "No visible effect observed. Stock is on."
                )

                boolKnob(
                    title: "Force Update When Inactive",
                    keyPath: \.forceUpdateWhenInactive,
                    stock: PrivateSpatial3DSettings.Stock.forceUpdateWhenInactive,
                    caption: "No visible effect observed. Stock is off."
                )
                #else
                Text("Three further knobs (User Interaction Enabled, MXI Render Two-Pass, Force Update When Inactive) exist only on visionOS 27. Build with HYPNOS_PRIVATE_API_V27 and a 27.0 deployment target to expose them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                Button("Reset All Overrides") { store.reset() }
                    .disabled(store.settings.isNoOp)
            }
        }
    }

    // MARK: - Knob builders

    #if HYPNOS_PRIVATE_API_V27
    /// The zero-parallax alignment mode. RealityKit may re-assert its own value
    /// when entering the immersive presentation; the tuning is re-applied on
    /// every viewing-mode change, so toggle 3D off and on after changing it.
    @ViewBuilder
    private func repositionModeKnob() -> some View {
        let presence = presenceBinding(
            \.sceneRepositionMode,
            stock: PrivateSpatial3DSettings.Stock.sceneRepositionMode
        )
        Toggle("Override Scene Reposition Mode", isOn: presence)
        if presence.wrappedValue {
            Picker("Scene Reposition Mode", selection: valueBinding(
                \.sceneRepositionMode,
                stock: PrivateSpatial3DSettings.Stock.sceneRepositionMode
            )) {
                ForEach(PrivateSceneRepositionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        Text("Confirmed fix for the visionOS 27 immersive change. Align to Head Position restores the pre-27 static portal; Align to View Depth is the stock 27 behaviour that zooms toward the subject and shifts with viewpoint. The mapping is the opposite of what the names suggest.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    #endif

    /// Binding that turns an override on (seeding it with the stock value) or off.
    private func presenceBinding<T>(
        _ keyPath: WritableKeyPath<PrivateSpatial3DSettings, T?>,
        stock: T
    ) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] != nil },
            set: { on in
                var s = store.settings
                s[keyPath: keyPath] = on ? stock : nil
                store.settings = s
                store.markChanged()
            }
        )
    }

    private func valueBinding<T>(
        _ keyPath: WritableKeyPath<PrivateSpatial3DSettings, T?>,
        stock: T
    ) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] ?? stock },
            set: { v in
                var s = store.settings
                s[keyPath: keyPath] = v
                store.settings = s
                store.markChanged()
            }
        )
    }

    @ViewBuilder
    private func floatKnob(
        title: String,
        keyPath: WritableKeyPath<PrivateSpatial3DSettings, Float?>,
        stock: Float,
        range: ClosedRange<Float>,
        caption: String
    ) -> some View {
        let presence = presenceBinding(keyPath, stock: stock)
        Toggle("Override \(title)", isOn: presence)
        if presence.wrappedValue {
            let value = valueBinding(keyPath, stock: stock)
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.3f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func boolKnob(
        title: String,
        keyPath: WritableKeyPath<PrivateSpatial3DSettings, Bool?>,
        stock: Bool,
        caption: String
    ) -> some View {
        let presence = presenceBinding(keyPath, stock: stock)
        Toggle("Override \(title)", isOn: presence)
        if presence.wrappedValue {
            Toggle(title, isOn: valueBinding(keyPath, stock: stock))
        }
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#endif
