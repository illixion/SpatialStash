/*
 Spatial Stash - Remote Alert Window Value

 Window value for WebSocket-triggered text alert windows.
 */

import Foundation

struct RemoteAlertWindowValue: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let bgColorHex: String
    let imageUrl: String?

    init(text: String, bgColorHex: String = "#000000", imageUrl: String? = nil) {
        self.id = UUID()
        self.text = text
        self.bgColorHex = bgColorHex
        self.imageUrl = imageUrl
    }
}
