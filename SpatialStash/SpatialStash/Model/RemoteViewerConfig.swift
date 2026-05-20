/*
 Spatial Stash - Remote Viewer Configuration

 Stores per-viewer settings (display, API endpoint, etc.). Saved
 configurations are persisted to UserDefaults.

 Tag lists, blocked posts, and blocked tags are owned by the RoboFrame
 server and pushed over the WebSocket on connect — they are not stored
 here.
 */

import Foundation

/// Per-slideshow 3D rendering mode. When non-`.off`, each image is loaded
/// into a RealityKit `ImagePresentationComponent` instead of a 2D SwiftUI
/// `Image`, and Ken Burns + Diorama are bypassed (RealityKit owns the
/// rendered geometry, so the SwiftUI transforms don't apply).
enum Slideshow3DMode: String, Codable, CaseIterable, Identifiable {
    case off
    case spatial3D
    case immersive3D

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "2D"
        case .spatial3D: return "3D"
        case .immersive3D: return "Immersive 3D"
        }
    }
    var systemImage: String {
        // Match the icons used by the regular picture viewer's 3D menu so
        // the slideshow ornament is visually consistent.
        switch self {
        case .off: return "view.3d"
        case .spatial3D: return "spatial.capture.fill"
        case .immersive3D: return "inset.filled.pano"
        }
    }
}

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
    var enableDiorama: Bool = false
    var transparentBackground: Bool = false
    var textSize: Double = 1.0

    /// Slideshow 3D rendering mode. `.off` uses the regular 2D SwiftUI image
    /// pipeline. `.spatial3D`/`.immersive3D` load each image into a RealityKit
    /// `ImagePresentationComponent` and override Ken Burns + Diorama.
    var slideshow3DMode: Slideshow3DMode = .off

    /// Per-profile cap for the 2D slideshow image pipeline. `nil` = inherit
    /// `AppModel.slideshowMaxImageResolution2D`.
    var maxImageResolution2D: Int?

    /// Per-profile cap fed into RealityKit when slideshow 3D is enabled.
    /// `nil` = inherit `AppModel.slideshowMaxImageResolution3D`.
    var maxImageResolution3D: Int?

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
        case enableDynamicBrightness, enableDiorama
        case transparentBackground, textSize
        case slideshow3DMode, maxImageResolution2D, maxImageResolution3D
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
        enableDiorama = try container.decodeIfPresent(Bool.self, forKey: .enableDiorama) ?? false
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        textSize = try container.decodeIfPresent(Double.self, forKey: .textSize) ?? 1.0
        slideshow3DMode = try container.decodeIfPresent(Slideshow3DMode.self, forKey: .slideshow3DMode) ?? .off
        maxImageResolution2D = try container.decodeIfPresent(Int.self, forKey: .maxImageResolution2D)
        maxImageResolution3D = try container.decodeIfPresent(Int.self, forKey: .maxImageResolution3D)

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
        try container.encode(enableDiorama, forKey: .enableDiorama)
        try container.encode(transparentBackground, forKey: .transparentBackground)
        try container.encode(textSize, forKey: .textSize)
        try container.encode(slideshow3DMode, forKey: .slideshow3DMode)
        try container.encodeIfPresent(maxImageResolution2D, forKey: .maxImageResolution2D)
        try container.encodeIfPresent(maxImageResolution3D, forKey: .maxImageResolution3D)

        try container.encode(homeAssistantURL, forKey: .homeAssistantURL)
    }
}
