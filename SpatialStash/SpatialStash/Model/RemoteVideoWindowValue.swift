/*
 Spatial Stash - Remote Video Window Value

 Window value for WebSocket-triggered video playback windows.
 */

import Foundation

struct RemoteVideoWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    let videoURL: URL

    init(videoURL: URL) {
        self.id = UUID()
        self.videoURL = videoURL
    }
}
