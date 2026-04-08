/*
 Spatial Stash - Remote Viewer Window Value

 Codable/Hashable value passed to the remote viewer WindowGroup.
 Each instance gets a unique ID so visionOS creates a new window.
 */

import Foundation

struct RemoteViewerWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    let configId: UUID

    init(configId: UUID) {
        self.id = UUID()
        self.configId = configId
    }
}
