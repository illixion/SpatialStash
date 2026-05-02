/*
 Spatial Stash - Window Session Registry

 Tracks the number of open "main" windows and exposes an OpenWindowAction
 captured from a SwiftUI environment so app/scene lifecycle hooks can summon
 the main window even when only pop-out scenes are currently connected.
 */

import os
import SwiftUI

@MainActor
final class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()

    private(set) var mainWindowCount: Int = 0

    /// Most recently captured `openWindow` action from a SwiftUI view.
    /// Updated by every WindowGroup's content on appear so we have a live
    /// reference whichever scene happens to be rendered.
    var openWindow: OpenWindowAction?

    private init() {}

    func registerMainWindow() {
        mainWindowCount += 1
    }

    func unregisterMainWindow() {
        mainWindowCount = max(0, mainWindowCount - 1)
    }

    /// Opens the main window if none is currently visible. Safe to call from
    /// scene/app lifecycle hooks; no-ops when a main window is already open.
    func ensureMainWindowVisible() {
        guard mainWindowCount == 0 else { return }
        guard let openWindow else {
            AppLogger.windowState.warning("ensureMainWindowVisible: no openWindow action captured")
            return
        }
        AppLogger.windowState.info("ensureMainWindowVisible: summoning main window")
        openWindow(id: "main", value: UUID())
    }
}

/// Captures the current `openWindow` action into `WindowSessionRegistry`
/// so non-main scene roots also keep the shared reference fresh.
private struct CaptureOpenWindowModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowSessionRegistry.shared.openWindow = openWindow
        }
    }
}

extension View {
    func captureOpenWindowAction() -> some View {
        modifier(CaptureOpenWindowModifier())
    }
}
