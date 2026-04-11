/*
 Spatial Stash - Remote Viewer Configuration

 Stores settings for a Remote API Viewer instance.
 Saved configurations are persisted to UserDefaults.

 Tag lists are now managed separately by TagListManager and
 shared across all viewer windows.
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

    // Content (blocking only — tag lists moved to TagListManager)
    var blockedPosts: [Int] = []
    var blockedTags: [String] = []

    // Home Assistant
    var homeAssistantURL: String = ""

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.savedDate = Date()
    }

    // MARK: - Legacy Migration

    /// Legacy tag list fields preserved for decoding old configs.
    /// Used by TagListManager.importFromConfig() during migration.
    var legacyTagLists: [[String]] {
        _legacyTagLists ?? []
    }
    var legacyDefaultTagListIndex: Int? {
        _legacyDefaultTagListIndex
    }
    var legacyLastActiveTagListIndex: Int? {
        _legacyLastActiveTagListIndex
    }

    // Private storage for legacy fields (only populated when decoding old configs)
    private var _legacyTagLists: [[String]]?
    private var _legacyDefaultTagListIndex: Int?
    private var _legacyLastActiveTagListIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, savedDate
        case apiEndpoint, wsEndpoint, wsDeviceId
        case delay, showClock, showSensors, useAspectRatio, enableKenBurns
        case transparentBackground, textSize
        case blockedPosts, blockedTags
        case homeAssistantURL
        // Legacy keys — decoded but no longer encoded
        case tagLists, defaultTagListIndex, lastActiveTagListIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedDate = try container.decode(Date.self, forKey: .savedDate)

        apiEndpoint = try container.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? "https://example.com/api"
        wsEndpoint = try container.decodeIfPresent(String.self, forKey: .wsEndpoint) ?? ""
        wsDeviceId = try container.decodeIfPresent(String.self, forKey: .wsDeviceId) ?? ""

        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? 15
        showClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
        showSensors = try container.decodeIfPresent(Bool.self, forKey: .showSensors) ?? true
        useAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .useAspectRatio) ?? true
        enableKenBurns = try container.decodeIfPresent(Bool.self, forKey: .enableKenBurns) ?? true
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        textSize = try container.decodeIfPresent(Double.self, forKey: .textSize) ?? 1.0

        blockedPosts = try container.decodeIfPresent([Int].self, forKey: .blockedPosts) ?? []
        blockedTags = try container.decodeIfPresent([String].self, forKey: .blockedTags) ?? []

        homeAssistantURL = try container.decodeIfPresent(String.self, forKey: .homeAssistantURL) ?? ""

        // Decode legacy tag list fields for migration
        _legacyTagLists = try container.decodeIfPresent([[String]].self, forKey: .tagLists)
        _legacyDefaultTagListIndex = try container.decodeIfPresent(Int.self, forKey: .defaultTagListIndex)
        _legacyLastActiveTagListIndex = try container.decodeIfPresent(Int.self, forKey: .lastActiveTagListIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(savedDate, forKey: .savedDate)

        try container.encode(apiEndpoint, forKey: .apiEndpoint)
        try container.encode(wsEndpoint, forKey: .wsEndpoint)
        try container.encode(wsDeviceId, forKey: .wsDeviceId)

        try container.encode(delay, forKey: .delay)
        try container.encode(showClock, forKey: .showClock)
        try container.encode(showSensors, forKey: .showSensors)
        try container.encode(useAspectRatio, forKey: .useAspectRatio)
        try container.encode(enableKenBurns, forKey: .enableKenBurns)
        try container.encode(transparentBackground, forKey: .transparentBackground)
        try container.encode(textSize, forKey: .textSize)

        try container.encode(blockedPosts, forKey: .blockedPosts)
        try container.encode(blockedTags, forKey: .blockedTags)

        try container.encode(homeAssistantURL, forKey: .homeAssistantURL)
        // Legacy tag list fields are intentionally NOT encoded
    }
}
