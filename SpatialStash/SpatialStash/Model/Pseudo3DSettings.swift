/*
 Spatial Stash - Pseudo 3D Settings

 Per-window tuning for the "fake 3D" video conversion. The mono frame is warped
 per-eye in a Metal fragment shader (see videoPseudo3DEyeFragmentShader) against
 a real depth map — Core ML inference per frame (realtime) or a pre-processed
 DepthCacheStore entry. There is no heuristic-depth fallback.

 `depthStrength` is the maximum horizontal disparity expressed in normalized UV
 (a fraction of frame width). `convergence` selects which depth sample sits on
 the window plane (disparity = (depth - convergence) * depthStrength): content
 nearer than it pops out, farther content recedes.

 Note the depth scale is inverse depth — 1 is the NEAR end — so raising
 convergence pushes the scene *back*, it doesn't bring it forward. At 1.0 every
 frame's nearest content lands on the glass and nothing can cross in front of
 the window frame. Since the realtime map is min/max normalized per frame (see
 CoreMLDepthProvider.makeTexture), 1.0 is scene-adaptive for free.
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
    /// Depth (0..1, inverse — 1 = near) that maps to zero parallax / the window
    /// plane. Higher pushes the scene back; 1.0 puts each frame's nearest
    /// content on the glass with everything behind it.
    ///
    /// Defaults to 1.0, which on-device reads correctly across content: the
    /// realtime map is min/max normalized per frame, so 1.0 tracks each frame's
    /// own near point (scene-adaptive for free) and nothing can cross in front
    /// of the window frame. The prior 0.45 put mid-depth on the glass and
    /// pushed over half of every frame out through the window.
    var convergence: Double = 1.0
    /// The default this replaced. Normalized away on decode (see `init(from:)`).
    static let legacyConvergenceDefault = 0.45

    static let `default` = Pseudo3DSettings()

    /// Whether these differ from the neutral defaults (used for per-window vs
    /// global fallback and to enable Reset, mirroring VisualAdjustments).
    var isModified: Bool { self != Pseudo3DSettings.default }
}

extension Pseudo3DSettings {
    private enum CodingKeys: String, CodingKey {
        case depthStrength, convergence
    }

    /// Hand-written so previously persisted JSON (UserDefaults global settings,
    /// per-window VideoWindowValue) keeps decoding as fields are added —
    /// synthesized Codable would throw on the missing key and silently reset
    /// users to `.default`. Retired keys (`autoConvergence`) need no handling:
    /// keyed decoding ignores JSON keys with no matching case.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Pseudo3DSettings()
        // The renderer intentionally ignores this legacy field. Normalizing old
        // persisted values prevents them from making an otherwise-default
        // per-window setting shadow the active global convergence settings.
        depthStrength = defaults.depthStrength
        let decodedConvergence = try container.decodeIfPresent(Double.self, forKey: .convergence)
            ?? defaults.convergence
        // Adopt the new default for anyone still carrying the old one. Two
        // reasons this can't just be left alone: a persisted global would keep
        // the old plane forever, and — because `isModified` compares against
        // `.default` — a per-window 0.45 would start counting as "modified" and
        // shadow the global (the same trap the legacy depthStrength above
        // sidesteps). Safe to key on the exact value: the slider is continuous
        // and unstepped, so 0.45 is only ever reachable as the old default.
        convergence = decodedConvergence == Self.legacyConvergenceDefault
            ? defaults.convergence
            : decodedConvergence
    }
}
