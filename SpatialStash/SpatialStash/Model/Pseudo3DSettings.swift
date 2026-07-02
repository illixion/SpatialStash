/*
 Spatial Stash - Pseudo 3D Settings

 Per-window tuning for the real-time "fake 3D" video conversion. The mono frame
 is warped per-eye in a Metal fragment shader (see videoPseudo3DEyeFragmentShader)
 using a cheap heuristic depth estimate, so there is no pre-compute step.

 `depthStrength` is the maximum horizontal disparity expressed in normalized UV
 (a fraction of frame width). `convergence` is the depth value (0 = far, 1 = near)
 mapped to zero parallax — pixels at this depth sit on the window plane, nearer
 pixels pop out, farther pixels recede.
 */

import Foundation

/// How fake-3D gets its depth: live per-frame inference (30fps, instant) or a
/// pre-processed DepthCacheStore entry (60fps, exact-frame sync, no ANE load).
/// Not persisted — resolved each time the user engages Convert to 3D.
enum Pseudo3DDepthMode: Equatable {
    case realtime
    /// The identity is the key DepthCacheStore entries were converted under
    /// (stash ID / local-file identity).
    case cached(videoIdentity: String)
}

struct Pseudo3DSettings: Codable, Hashable {
    /// Max per-eye horizontal disparity in UV space (fraction of frame width).
    /// Defaults to the Subtle preset: the *angular* separation the eyes see
    /// scales with the video window's apparent size — a large window amplifies
    /// it, and the system can't undo an over-large baked disparity (not
    /// IPD-scaled) — so start conservative and let the user increase it.
    var depthStrength: Double = 0.008
    /// Depth (0..1) that maps to zero parallax / the window plane.
    var convergence: Double = 0.45
    /// Track the video's (lookahead-smoothed) median depth as the zero-parallax
    /// plane, keeping the main subject on the window plane as scenes change.
    /// Effective only for pre-processed fake-3D (realtime has no median); the
    /// manual Convergence slider is disabled while on.
    var autoConvergence: Bool = false

    /// Slider bounds for the Adjustments "Stereo Separation" control.
    static let depthStrengthRange: ClosedRange<Double> = 0.0...0.04

    static let `default` = Pseudo3DSettings()

    /// Whether these differ from the neutral defaults (used for per-window vs
    /// global fallback and to enable Reset, mirroring VisualAdjustments).
    var isModified: Bool { self != Pseudo3DSettings.default }

    // Convenience depth presets surfaced in the ornament menu. Preset buttons
    // must MUTATE strength/convergence rather than replace the struct, so
    // toggles like autoConvergence survive a preset tap.
    static let subtle = Pseudo3DSettings(depthStrength: 0.008, convergence: 0.45)
    static let medium = Pseudo3DSettings(depthStrength: 0.018, convergence: 0.45)
    static let strong = Pseudo3DSettings(depthStrength: 0.03, convergence: 0.45)
}

extension Pseudo3DSettings {
    private enum CodingKeys: String, CodingKey {
        case depthStrength, convergence, autoConvergence
    }

    /// Hand-written so previously persisted JSON (UserDefaults global settings,
    /// per-window VideoWindowValue) keeps decoding as fields are added —
    /// synthesized Codable would throw on the missing key and silently reset
    /// users to `.default`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Pseudo3DSettings()
        depthStrength = try container.decodeIfPresent(Double.self, forKey: .depthStrength) ?? defaults.depthStrength
        convergence = try container.decodeIfPresent(Double.self, forKey: .convergence) ?? defaults.convergence
        autoConvergence = try container.decodeIfPresent(Bool.self, forKey: .autoConvergence) ?? defaults.autoConvergence
    }
}
