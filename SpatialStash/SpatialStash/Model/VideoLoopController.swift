/*
 Spatial Stash - Video Loop Controller

 Per-window @Observable model that drives the A-B loop feature on the
 web video player. Each press of the control-bar button advances through:

   idle → aSet → active → idle

 - idle  → aSet   : capture current playback time as A
 - aSet  → active : capture current playback time as B and engage the loop
                    immediately (JS rVFC monitor seeks back to A near B)
 - active → idle  : disable, clear points

 The loop engages on the second press — there is no separate confirmation
 step. A/B points are surfaced as markers on the scrubber so the user can
 see them before/after engaging, and a clear button removes the loop.

 Owns its own toast message (mirroring the remote viewer pattern); the
 host view renders it as feedback for each transition.
 */

import SwiftUI

@MainActor
@Observable
final class VideoLoopController {
    enum State {
        case idle
        case aSet
        case active
    }

    private(set) var state: State = .idle
    private(set) var pointA: Double?
    private(set) var pointB: Double?

    var toastMessage: String?
    var toastIsError: Bool = false

    /// Set by the player view: returns the current playback time in seconds.
    @ObservationIgnored
    var queryCurrentTime: (@MainActor () async -> Double?)?

    /// Set by the player view: pushes loop bounds to the JS rVFC monitor.
    /// Pass `nil`, `nil` to disable.
    @ObservationIgnored
    var setLoopBounds: (@MainActor (_ a: Double?, _ b: Double?) -> Void)?

    @ObservationIgnored
    private var toastDismissTask: Task<Void, Never>?

    /// Cycle state on button tap. Each press advances one step.
    func handleButtonTap() async {
        switch state {
        case .idle:
            guard let t = await queryCurrentTime?() else {
                showToast("Couldn't read playback time", isError: true)
                return
            }
            pointA = t
            state = .aSet
            showToast("Loop start (A) set at \(formatTime(t))")

        case .aSet:
            guard let t = await queryCurrentTime?() else {
                showToast("Couldn't read playback time", isError: true)
                return
            }
            let a = pointA ?? 0
            // Require at least one frame between A and B
            guard t > a + 1.0 / 30.0 else {
                showToast("End point must be after start point", isError: true)
                return
            }
            // Capture B and engage the loop immediately (no confirmation step).
            pointB = t
            state = .active
            setLoopBounds?(a, t)
            showToast("A-B Loop enabled (\(formatTime(a))–\(formatTime(t)))")

        case .active:
            clearLoop(showToast: true)
        }
    }

    /// Clear the loop from a user action (shows a toast if a loop was live).
    func clear() {
        clearLoop(showToast: true)
    }

    /// Reset to idle without showing a toast. Called when the video changes.
    func reset() {
        clearLoop(showToast: false)
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastMessage = nil
    }

    var iconName: String {
        switch state {
        case .idle:   return "point.forward.to.point.capsulepath"
        case .aSet:   return "a.square"
        case .active: return "point.forward.to.point.capsulepath.fill"
        }
    }

    var isEngaged: Bool {
        state == .active
    }

    var helpText: String {
        switch state {
        case .idle:   return "Set Loop Start (A)"
        case .aSet:   return "Set Loop End (B) & Loop"
        case .active: return "Disable A-B Loop"
        }
    }

    // MARK: - Internals

    private func clearLoop(showToast: Bool) {
        let wasLive = (state == .active)
        state = .idle
        pointA = nil
        pointB = nil
        setLoopBounds?(nil, nil)
        if showToast && wasLive {
            self.showToast("A-B Loop disabled")
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastIsError = isError
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            withAnimation { self.toastMessage = nil }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
