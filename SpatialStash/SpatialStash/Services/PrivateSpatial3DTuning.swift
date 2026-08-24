//
//  PrivateSpatial3DTuning.swift
//  SpatialStash
//
//  GitHub-only build feature. Compiled out entirely unless the
//  SPATIALSTASH_PRIVATE_API compilation condition is set (see
//  Configuration/SpatialStash.xcconfig and scripts/build-and-sign.sh
//  --private-api). App Store builds must never define it: the accessors below
//  bind to symbols that exist in the shipping RealityFoundation binary but are
//  declared in no public header.
//

#if SPATIALSTASH_PRIVATE_API

import Foundation
import Observation
import os
import RealityKit

// MARK: - Why this file exists
//
// visionOS 27 changed how ImagePresentationComponent presents .spatial3DImmersive:
// instead of a static portal it zooms toward the subject and shifts the view with
// the viewer's head position. CoreRE's own log strings name the mechanism —
// "after adaptive scene scaling, scalar %f, modelScale %f" and "Update viewing
// distance to %f (... isWindowRepositioned ... isIPCEntityRepositioned)".
//
// No public API was added in the 27.0 SDK to control it: the public
// ImagePresentationComponent surface is byte-for-byte identical to 26.5. The
// runtime, however, gained several stored properties that ARE ABI-exported and
// listed in the SDK's .tbd, so they can be linked and called directly.
//
// MARK: Calling convention (important)
//
// These declarations MUST live inside an extension. A global @_silgen_name func
// passes every parameter in the normal argument registers, but Swift's method
// convention passes `self` in a dedicated register (x20 on arm64). Declaring
// them globally compiles and links fine and then silently reads and writes the
// wrong memory — verified on the visionOS 27 simulator, where a global-func
// setter left values unchanged and a getter returned 1.18e-35. Declared as
// extension methods, every knob below round-trips exactly.
//
// MARK: Resilient enum properties
//
// mxiSceneRepositionMode is an MXIComponent.MXISceneRepositionMode, a two-case
// enum {alignToViewDepth, alignToHeadPosition}. Being resilient it is passed and
// returned INDIRECTLY, so it needs different signatures from the Bool/Float
// knobs above — a direct-value declaration crashes the process:
//
//   * setter takes it @in, i.e. an address in the first argument register, which
//     an extension method expresses as UnsafeRawPointer.
//   * getter returns it @out, i.e. into a caller-supplied buffer whose address
//     arrives in x8. Declaring the return as a 64-byte struct reproduces that,
//     because Swift returns anything that large indirectly.
//
// Verified round-tripping on visionOS 27.0 (24M5326f).
//
// MARK: Deliberately excluded
//
//   * mxiTuningOverrides ([String: Any]) — accepts the CoreRE tuning keys
//     (enableAdaptiveScaling, allowReposition, customSceneScale, sceneScale, …)
//     but is not a plain stored property: a 4-key write reads back as 0 entries,
//     and repeated access returns a corrupt Dictionary. Unsafe to touch.

/// Buffer for an `@out` return. Large enough (64 bytes) that Swift returns it
/// indirectly via x8, matching the resilient-enum getter convention. Only the
/// first byte is meaningful for a payload-free two-case enum.
private struct PrivateOutBuffer64 {
    var a = 0, b = 0, c = 0, d = 0, e = 0, f = 0, g = 0, h = 0
}

/// Zero-parallax alignment for the immersive spatial-3D scene.
///
/// Confirmed on device (visionOS 27.0). The mapping is the opposite of what the
/// case names suggest, so don't "fix" it from intuition:
///
///   * `alignToViewDepth` — the **stock visionOS 27 value**, and the behaviour
///     change itself: zooms toward the subject and shifts the view with the
///     viewer's head position.
///   * `alignToHeadPosition` — **restores the pre-27 static portal**.
enum PrivateSceneRepositionMode: UInt8, Codable, CaseIterable, Identifiable {
    case alignToViewDepth = 0
    case alignToHeadPosition = 1

    /// The value that reproduces the pre-visionOS 27 presentation.
    static let restoresLegacyPresentation = PrivateSceneRepositionMode.alignToHeadPosition

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .alignToViewDepth: "Align to View Depth"
        case .alignToHeadPosition: "Align to Head Position"
        }
    }
}

// MARK: - Private accessors

extension ImagePresentationComponent {

    // Available since visionOS 26 — safe at the app's 26.0 deployment target.

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV25spatial3DCollapseStrengthSfvg")
    func __privateGetCollapseStrength() -> Float
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV25spatial3DCollapseStrengthSfvs")
    mutating func __privateSetCollapseStrength(_ newValue: Float)

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV20cornerRadiusInPointsSfvg")
    func __privateGetCornerRadiusInPoints() -> Float
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV20cornerRadiusInPointsSfvs")
    mutating func __privateSetCornerRadiusInPoints(_ newValue: Float)

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV31enableSpecularAndFresnelEffectsSbvg")
    func __privateGetSpecularAndFresnelEffects() -> Bool
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV31enableSpecularAndFresnelEffectsSbvs")
    mutating func __privateSetSpecularAndFresnelEffects(_ newValue: Bool)

    #if SPATIALSTASH_PRIVATE_API_V27
    // New in visionOS 27. These symbols do NOT exist in 26.x, and a missing
    // non-weak symbol is a dyld failure at launch, not a recoverable error —
    // so a build defining this condition must also raise
    // XROS_DEPLOYMENT_TARGET to 27.0.

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV24isUserInteractionEnabledSbvg")
    func __privateGetUserInteractionEnabled() -> Bool
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV24isUserInteractionEnabledSbvs")
    mutating func __privateSetUserInteractionEnabled(_ newValue: Bool)

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV16mxiRenderTwoPassSbvg")
    func __privateGetRenderTwoPass() -> Bool
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV16mxiRenderTwoPassSbvs")
    mutating func __privateSetRenderTwoPass(_ newValue: Bool)

    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV29enableForceUpdateWhenInactiveSbvg")
    func __privateGetForceUpdateWhenInactive() -> Bool
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV29enableForceUpdateWhenInactiveSbvs")
    mutating func __privateSetForceUpdateWhenInactive(_ newValue: Bool)

    // Resilient enum — indirect conventions, see the note above. fileprivate
    // because the @out buffer type is file-scoped; the wrappers below are the
    // supported entry points.
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV22mxiSceneRepositionModeAA12MXIComponentV08MXIScenehI0Ovg")
    fileprivate func __privateGetSceneRepositionModeOut() -> PrivateOutBuffer64
    @_silgen_name("$s17RealityFoundation26ImagePresentationComponentV22mxiSceneRepositionModeAA12MXIComponentV08MXIScenehI0Ovs")
    fileprivate mutating func __privateSetSceneRepositionModeIn(_ value: UnsafeRawPointer)
    #endif
}

#if SPATIALSTASH_PRIVATE_API_V27
extension ImagePresentationComponent {
    /// Raw tag of `mxiSceneRepositionMode`, read through the `@out` convention.
    var privateSceneRepositionModeRaw: UInt8 {
        withUnsafeBytes(of: __privateGetSceneRepositionModeOut()) { $0[0] }
    }

    /// Write `mxiSceneRepositionMode` through the `@in` convention.
    mutating func privateSetSceneRepositionMode(_ mode: PrivateSceneRepositionMode) {
        var raw = mode.rawValue
        withUnsafeBytes(of: &raw) { __privateSetSceneRepositionModeIn($0.baseAddress!) }
    }
}
#endif

// MARK: - Settings

/// Per-knob overrides. `nil` means "leave RealityKit's value alone", so an
/// all-`nil` value is a guaranteed no-op and the shipped default.
struct PrivateSpatial3DSettings: Codable, Equatable {
    var collapseStrength: Float?
    var cornerRadiusInPoints: Float?
    var specularAndFresnelEffects: Bool?
    var userInteractionEnabled: Bool?
    var renderTwoPass: Bool?
    var forceUpdateWhenInactive: Bool?
    var sceneRepositionMode: PrivateSceneRepositionMode?

    var isNoOp: Bool {
        collapseStrength == nil && cornerRadiusInPoints == nil
            && specularAndFresnelEffects == nil && userInteractionEnabled == nil
            && renderTwoPass == nil && forceUpdateWhenInactive == nil
            && sceneRepositionMode == nil
    }

    /// Values observed on visionOS 27.0 (24M5326f), shown in the UI so a knob
    /// can be returned to stock without guessing.
    enum Stock {
        static let collapseStrength: Float = 0.0
        static let cornerRadiusInPoints: Float = 44.0
        static let specularAndFresnelEffects = true
        static let userInteractionEnabled = true
        static let renderTwoPass = true
        static let forceUpdateWhenInactive = false
        static let sceneRepositionMode = PrivateSceneRepositionMode.alignToViewDepth
    }
}

/// Persisted store for the private tuning. Separate from `AppModel` so the
/// App Store build carries no trace of it.
@MainActor
@Observable
final class PrivateSpatial3DTuningStore {
    static let shared = PrivateSpatial3DTuningStore()

    private static let enabledKey = "privateSpatial3DTuningEnabled"
    private static let settingsKey = "privateSpatial3DTuningSettings"

    /// Master switch. Off by default, so even a --private-api build behaves
    /// exactly like a stock build until it is deliberately turned on.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            syncNudgeSuppression()
        }
    }

    var settings: PrivateSpatial3DSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
            syncNudgeSuppression()
        }
    }

    /// Turning MXI Render Two-Pass off shows the raw gaussian splat directly;
    /// the calibration nudge exists to fix IPC's off-axis blur in the normal
    /// two-pass render, so it has nothing to fix — and can visibly glitch the
    /// raw splat — once two-pass is off.
    private static let renderTwoPassOffNudgeReason = "mxiRenderTwoPassOff"

    private func syncNudgeSuppression() {
        let shouldSuppress = isEnabled && settings.renderTwoPass == false
        WindowSizeNudge.setSuppressed(shouldSuppress, reason: Self.renderTwoPassOffNudgeReason)
    }

    /// Bumped whenever the values change so open viewers can re-apply.
    private(set) var revision: Int = 0

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(PrivateSpatial3DSettings.self, from: data) {
            settings = decoded
        } else {
            settings = PrivateSpatial3DSettings()
        }
        // didSet doesn't fire for a property's own initial assignment above,
        // so establish suppression state from whatever was just restored.
        syncNudgeSuppression()
    }

    func markChanged() { revision &+= 1 }

    func reset() {
        settings = PrivateSpatial3DSettings()
        markChanged()
    }

    /// Whether the tuning should touch components at all.
    var isActive: Bool { isEnabled && !settings.isNoOp }

    /// Apply the overrides to `component`, returning true if anything changed.
    @discardableResult
    func apply(to component: inout ImagePresentationComponent) -> Bool {
        guard isActive else { return false }
        var changed = false

        if let v = settings.collapseStrength, component.__privateGetCollapseStrength() != v {
            component.__privateSetCollapseStrength(v); changed = true
        }
        if let v = settings.cornerRadiusInPoints, component.__privateGetCornerRadiusInPoints() != v {
            component.__privateSetCornerRadiusInPoints(v); changed = true
        }
        if let v = settings.specularAndFresnelEffects,
           component.__privateGetSpecularAndFresnelEffects() != v {
            component.__privateSetSpecularAndFresnelEffects(v); changed = true
        }

        #if SPATIALSTASH_PRIVATE_API_V27
        if let v = settings.userInteractionEnabled,
           component.__privateGetUserInteractionEnabled() != v {
            component.__privateSetUserInteractionEnabled(v); changed = true
        }
        if let v = settings.renderTwoPass, component.__privateGetRenderTwoPass() != v {
            component.__privateSetRenderTwoPass(v); changed = true
        }
        if let v = settings.forceUpdateWhenInactive,
           component.__privateGetForceUpdateWhenInactive() != v {
            component.__privateSetForceUpdateWhenInactive(v); changed = true
        }
        if let v = settings.sceneRepositionMode,
           component.privateSceneRepositionModeRaw != v.rawValue {
            component.privateSetSceneRepositionMode(v); changed = true
        }
        #endif

        return changed
    }
}

// MARK: - PhotoWindowModel hook

extension PhotoWindowModel {
    /// Re-apply the private tuning to this window's ImagePresentationComponent.
    /// Called from `updateExperimentalSpatial3DTuning()`, which already runs at
    /// every point where the component is created or its viewing mode changes.
    /// Only re-publishes the component when a value actually changed, so this is
    /// free when the tuning is off.
    func applyPrivateSpatial3DTuning() {
        let store = PrivateSpatial3DTuningStore.shared
        guard store.isActive,
              var ipc = contentEntity.components[ImagePresentationComponent.self]
        else { return }

        guard store.apply(to: &ipc) else { return }
        contentEntity.components.set(ipc)
        AppLogger.photoWindow.log(
            level: AppLogger.effectiveDebugLevel,
            "Applied private spatial-3D tuning (rev \(store.revision, privacy: .public))"
        )
    }
}

#endif
