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

struct Pseudo3DSettings: Codable, Hashable {
    /// Max per-eye horizontal disparity in UV space (fraction of frame width).
    /// Defaults to the Subtle preset: the *angular* separation the eyes see
    /// scales with the video window's apparent size — a large window amplifies
    /// it, and the system can't undo an over-large baked disparity (not
    /// IPD-scaled) — so start conservative and let the user increase it.
    var depthStrength: Double = 0.008
    /// Depth (0..1) that maps to zero parallax / the window plane.
    var convergence: Double = 0.45

    /// Slider bounds for the Adjustments "Stereo Separation" control.
    static let depthStrengthRange: ClosedRange<Double> = 0.0...0.04

    static let `default` = Pseudo3DSettings()

    /// Whether these differ from the neutral defaults (used for per-window vs
    /// global fallback and to enable Reset, mirroring VisualAdjustments).
    var isModified: Bool { self != Pseudo3DSettings.default }

    // Convenience depth presets surfaced in the ornament menu.
    static let subtle = Pseudo3DSettings(depthStrength: 0.008, convergence: 0.45)
    static let medium = Pseudo3DSettings(depthStrength: 0.018, convergence: 0.45)
    static let strong = Pseudo3DSettings(depthStrength: 0.03, convergence: 0.45)
}
