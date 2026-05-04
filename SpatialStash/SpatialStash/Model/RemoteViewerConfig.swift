/*
 Spatial Stash - Remote Viewer Configuration

 Stores per-viewer settings (display, API endpoint, etc.). Saved
 configurations are persisted to UserDefaults.

 Tag lists, blocked posts, and blocked tags are owned by the RoboFrame
 server and pushed over the WebSocket on connect — they are not stored
 here.
 */

import Foundation

struct RemoteViewerConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    let savedDate: Date

    // API
    var apiEndpoint: String = "https://example.com/api"
    var wsDeviceId: String = ""
    var accessToken: String = ""

    // Display
    var delay: TimeInterval = 15
    var showClock: Bool = true
    var showSensors: Bool = true
    var useAspectRatio: Bool = true
    var enableKenBurns: Bool = true
    var enableDynamicBrightness: Bool = true
    var transparentBackground: Bool = false
    var textSize: Double = 1.0

    // Home Assistant
    var homeAssistantURL: String = ""

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.savedDate = Date()
    }

    /// Resolved WebSocket URL — derived from `apiEndpoint` by swapping the
    /// scheme (http→ws, https→wss) and appending `/rpc/ws`. Matches the kiosk
    /// frontend's behaviour, so a single API URL is enough to talk to a
    /// single-port RoboFrame deployment (root or sub-path).
    var effectiveWsEndpoint: String {
        var base = apiEndpoint.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return "" }
        if base.hasSuffix("/") { base.removeLast() }

        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        } else {
            // Bare scheme-less URL — prepend ws:// as a best-effort default.
            base = "ws://" + base
        }
        var url = base + "/rpc/ws"
        let token = accessToken.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            url += "?token=" + encoded
        }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, savedDate
        case apiEndpoint, wsDeviceId, accessToken
        case delay, showClock, showSensors, useAspectRatio, enableKenBurns
        case enableDynamicBrightness
        case transparentBackground, textSize
        case homeAssistantURL
        // Decoded silently from older saved configs and never re-encoded.
        case wsEndpoint
        case blockedPosts, blockedTags
        case tagLists, defaultTagListIndex, lastActiveTagListIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedDate = try container.decode(Date.self, forKey: .savedDate)

        apiEndpoint = try container.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? "https://example.com/api"
        wsDeviceId = try container.decodeIfPresent(String.self, forKey: .wsDeviceId) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""

        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? 15
        showClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
        showSensors = try container.decodeIfPresent(Bool.self, forKey: .showSensors) ?? true
        useAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .useAspectRatio) ?? true
        enableKenBurns = try container.decodeIfPresent(Bool.self, forKey: .enableKenBurns) ?? true
        enableDynamicBrightness = try container.decodeIfPresent(Bool.self, forKey: .enableDynamicBrightness) ?? true
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        textSize = try container.decodeIfPresent(Double.self, forKey: .textSize) ?? 1.0

        homeAssistantURL = try container.decodeIfPresent(String.self, forKey: .homeAssistantURL) ?? ""

        // Older saved configs may carry these fields. Swallow them so the
        // decode succeeds and they're dropped on next save — the server
        // is now authoritative on tag and blocked lists, and the WS URL
        // is always derived from `apiEndpoint`.
        _ = try container.decodeIfPresent(String.self, forKey: .wsEndpoint)
        _ = try container.decodeIfPresent([Int].self, forKey: .blockedPosts)
        _ = try container.decodeIfPresent([String].self, forKey: .blockedTags)
        _ = try container.decodeIfPresent([[String]].self, forKey: .tagLists)
        _ = try container.decodeIfPresent(Int.self, forKey: .defaultTagListIndex)
        _ = try container.decodeIfPresent(Int.self, forKey: .lastActiveTagListIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(savedDate, forKey: .savedDate)

        try container.encode(apiEndpoint, forKey: .apiEndpoint)
        try container.encode(wsDeviceId, forKey: .wsDeviceId)
        try container.encode(accessToken, forKey: .accessToken)

        try container.encode(delay, forKey: .delay)
        try container.encode(showClock, forKey: .showClock)
        try container.encode(showSensors, forKey: .showSensors)
        try container.encode(useAspectRatio, forKey: .useAspectRatio)
        try container.encode(enableKenBurns, forKey: .enableKenBurns)
        try container.encode(enableDynamicBrightness, forKey: .enableDynamicBrightness)
        try container.encode(transparentBackground, forKey: .transparentBackground)
        try container.encode(textSize, forKey: .textSize)

        try container.encode(homeAssistantURL, forKey: .homeAssistantURL)
    }
}
