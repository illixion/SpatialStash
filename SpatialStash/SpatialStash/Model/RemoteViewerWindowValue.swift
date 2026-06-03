/*
 Spatial Stash - Remote Viewer Window Value

 Codable/Hashable value passed to the remote viewer WindowGroup.
 Each instance gets a unique ID so visionOS creates a new window.
 */

import Foundation

struct RemoteViewerWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    let configId: UUID

    /// User's last-resolved window size, written back as the window is resized.
    /// Persisted by visionOS into the scene-restoration archive so a wall-snapped
    /// slideshow window can be restored to its custom size and aspect ratio after
    /// a cold relaunch. `nil` until the window has been sized at least once.
    var restoredSize: CodableSize?

    init(configId: UUID) {
        self.id = UUID()
        self.configId = configId
        self.restoredSize = nil
    }
}
