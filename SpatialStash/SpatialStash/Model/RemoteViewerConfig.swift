/*
 Spatial Stash - Remote Viewer Configuration

 Stores all settings for a Remote API Viewer instance.
 Saved configurations are persisted to UserDefaults.
 */

import Foundation

struct RemoteViewerConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    let savedDate: Date

    // API
    var apiEndpoint: String = "https://example.com/api"
    var wsEndpoint: String = ""
    var wsDeviceId: String = ""

    // Display
    var delay: TimeInterval = 15
    var showClock: Bool = true
    var showSensors: Bool = true
    var useAspectRatio: Bool = true
    var enableKenBurns: Bool = true
    var transparentBackground: Bool = false
    var textSize: Double = 1.0

    // Content
    var tagLists: [[String]] = [["order:random"]]
    var defaultTagListIndex: Int? = nil  // nil = let server decide via WS
    var lastActiveTagListIndex: Int?     // persisted for "Server Decides" recovery on relaunch
    var blockedPosts: [Int] = []
    var blockedTags: [String] = []

    // Home Assistant
    var homeAssistantURL: String = ""

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.savedDate = Date()
    }
}
