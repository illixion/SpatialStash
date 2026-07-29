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
    /// LEGACY, retained only so previously persisted JSON keeps decoding.
    /// Strength is no longer user-adjustable: on-device testing showed anything
    /// above this default demands more vergence than comfortably fuses (higher
    /// values push background disparity toward divergence), so the engine pins
    /// the warp to `Pseudo3DSettings.default.depthStrength` (attenuated on
    /// video planes wider than 1 m — see Pseudo3DStereoEngine.makePumpConfig)
    /// and ignores whatever this decodes to.
    var depthStrength: Double = 0.008
    /// Depth (0..1) that maps to zero parallax / the window plane.
    var convergence: Double = 0.45
    /// Track the video's (lookahead-smoothed) median depth as the zero-parallax
    /// plane, keeping the main subject on the window plane as scenes change.
    /// Effective only for pre-processed fake-3D (realtime has no median); the
    /// manual Convergence slider is disabled while on.
    var autoConvergence: Bool = false

    static let `default` = Pseudo3DSettings()

    /// Whether these differ from the neutral defaults (used for per-window vs
    /// global fallback and to enable Reset, mirroring VisualAdjustments).
    var isModified: Bool { self != Pseudo3DSettings.default }
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
        // The renderer intentionally ignores this legacy field. Normalizing old
        // persisted values prevents them from making an otherwise-default
        // per-window setting shadow the active global convergence settings.
        depthStrength = defaults.depthStrength
        convergence = try container.decodeIfPresent(Double.self, forKey: .convergence) ?? defaults.convergence
        autoConvergence = try container.decodeIfPresent(Bool.self, forKey: .autoConvergence) ?? defaults.autoConvergence
    }
}
