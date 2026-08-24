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

    /// Nudge `scene`'s geometry away from `base` by `delta` points, wait for
    /// visionOS to settle, then revert to `base`. No-op if suppressed. The
    /// revert always runs once started, independent of suppression changing
    /// mid-flight, so a window is never left stuck at the nudged size.
    static func perform(on scene: UIWindowScene, base: CGSize, delta: CGFloat) async {
        guard !isSuppressed else { return }
        let nudged = CGSize(width: base.width + delta, height: base.height + delta)
        UIView.performWithoutAnimation {
            scene.requestGeometryUpdate(.Vision(size: nudged))
        }
        try? await Task.sleep(for: .milliseconds(150))
        UIView.performWithoutAnimation {
            scene.requestGeometryUpdate(.Vision(size: base))
        }
    }
}
