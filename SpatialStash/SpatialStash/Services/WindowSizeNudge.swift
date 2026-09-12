//
//  WindowSizeNudge.swift
//  SpatialStash
//
//  Shared "grow a window by a point, wait, shrink it back" primitive. Used to
//  force ImagePresentationComponent to re-anchor its off-axis blur
//  calibration and, separately, as a last-resort kick for a stalled Metal/
//  RealityKit renderer. PhotoDisplayView, PhotoWindowView and
//  RemoteViewerWindowView each perform the actual geometry dance through this
//  one implementation so there's a single place to suppress it from.
//

import SwiftUI

@MainActor
enum WindowSizeNudge {
    /// Reasons currently suppressing every window-size nudge in the app. Any
    /// nonempty set means `perform` is a no-op. Keyed by reason so multiple
    /// independent callers can suppress without one's `setSuppressed(false)`
    /// clobbering another's still-active suppression.
    private static var suppressionReasons: Set<String> = []

    static var isSuppressed: Bool { !suppressionReasons.isEmpty }

    /// Turn a suppression reason on or off. Call with the same `reason`
    /// string to release exactly what you asked to suppress.
    static func setSuppressed(_ suppressed: Bool, reason: String) {
        if suppressed {
            suppressionReasons.insert(reason)
        } else {
            suppressionReasons.remove(reason)
        }
    }

    /// Nudge `scene`'s geometry by `delta` points, wait for visionOS to settle,
    /// then revert. No-op if suppressed. The revert always runs once started,
    /// independent of suppression changing mid-flight, so a window is never left
    /// stuck at the nudged size.
    ///
    /// The size reverted to is read from the scene here rather than supplied by
    /// the caller, because "the size to revert to" has exactly one correct
    /// answer and the callers used to disagree about it. Three read the scene's
    /// own geometry; the fourth passed a GeometryReader's content size, which is
    /// the documented cause of a ratchet — reverting to a content size sets the
    /// *scene* smaller by the chrome insets, and the next nudge measures the
    /// smaller window and shrinks again. That one fires on every tap on a 3D
    /// photo, so it had the most opportunities to walk a window down.
    static func perform(on scene: UIWindowScene, delta: CGFloat) async {
        guard !isSuppressed else { return }
        let base = scene.effectiveGeometry.coordinateSpace.bounds.size
        // Only guards against a degenerate scene: the nudge must not ask for a
        // non-positive size. A real minimum belongs to the persistence layer.
        guard base.width > 2, base.height > 2 else { return }
        let nudged = CGSize(width: base.width + delta, height: base.height + delta)
        WindowGeometry.request(scene, size: nudged)
        try? await Task.sleep(for: .milliseconds(150))
        WindowGeometry.request(scene, size: base)
    }
}
