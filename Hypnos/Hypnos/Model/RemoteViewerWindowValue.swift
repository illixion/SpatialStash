/*
 Hypnos - Remote Viewer Window Value

 Codable/Hashable value passed to the remote viewer WindowGroup.
 Each instance gets a unique ID so visionOS creates a new window.
 */

import Foundation
import RAVEUI

struct RemoteViewerWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    let configId: UUID

    /// User's last-resolved window size, written back as the window is resized.
    /// Persisted by visionOS into the scene-restoration archive so a wall-snapped
    /// slideshow window can be restored to its custom size and aspect ratio after
    /// a cold relaunch. `nil` until the window has been sized at least once.
    var restoredSize: RAVECodableSize?

    init(configId: UUID) {
        self.id = UUID()
        self.configId = configId
        self.restoredSize = nil
    }

    /// Identity is the window id alone. The synthesized conformance folded in
    /// `restoredSize`, so the moment the size write-back mutated it the value
    /// held by anything tracking this window (AppModel's open-window registry)
    /// no longer equalled the scene's live presentation value — and
    /// `openWindow(id:value:)` matched no scene, spawning a duplicate instead
    /// of summoning the existing window.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
