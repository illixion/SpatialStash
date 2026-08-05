/*
 Spatial Stash - Remote Viewer Configuration

 Stores per-viewer settings (display, API endpoint, etc.). Saved
 configurations are persisted to UserDefaults.

 The tag list (catalog and current selection), blocked posts, and blocked
 tags are owned by the RoboFrame server, which persists each channel's
 current list and pushes it over the WebSocket. None of it is stored here.
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

/// What a viewer profile actually opens. `.slideshow` is the original
/// RoboFrame / gallery slideshow; `.webPage` pins an arbitrary web page as an
/// interactive panel in the user's space (no slideshow engine, no WebSocket).
///
/// The raw values are persisted, so they keep the original spelling; only the
/// user-facing `label` names the actual thing each mode drives.
enum RemoteViewerMode: String, Codable, CaseIterable, Identifiable {
    case slideshow
    case webPage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slideshow: return "RoboFrame"
        case .webPage: return "Website"
        }
    }

    var systemImage: String {
        switch self {
        case .slideshow: return "photo.stack"
        case .webPage: return "globe"
        }
    }
}

/// `Equatable` is load-bearing for the Remote tab editor: it diffs the draft
/// against the profile it was loaded from to decide whether a Save would
/// overwrite anything, and against the stored copy to notice a viewer window
/// persisting its own change underneath the draft. Every stored property is
/// value-typed, so the synthesized `==` is the whole comparison — new fields
/// join it automatically.
struct RemoteViewerConfig: Codable, Identifiable, Equatable {
    private(set) var id: UUID
    var name: String
    private(set) var savedDate: Date

    /// Which window this profile launches. Defaults to `.slideshow` so every
    /// pre-existing saved profile keeps behaving exactly as before.
    var mode: RemoteViewerMode = .slideshow

    // API
    var apiEndpoint: String = "https://example.com/api"
    /// Stable RoboFrame device identity shared by slideshow windows and MQTT.
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

    // MARK: - Web page mode

    /// Page loaded by a `.webPage` profile. A scheme-less entry is treated as
    /// `https://` (see `resolvedWebPageURL`).
    var webPageURL: String = ""

    /// Injects CSS making `html`/`body` paint transparent, and makes the
    /// WebView itself non-opaque, so the page's own content floats in the
    /// user's space with no window backing.
    ///
    /// Deliberately *not* the slideshow's `transparentBackground`: that one is
    /// seeded from the user's slideshow defaults by
    /// `AppModel.applySlideshowDefaults(to:)`, and a page-transparency toggle
    /// silently inheriting a slideshow preference would be a surprise.
    var webTransparentBackground: Bool = false

    /// Seconds between automatic reloads. `0` (the default) disables it.
    /// The countdown restarts on page interaction, so a page being actively
    /// used isn't reloaded out from under the user.
    var webAutoRefreshInterval: TimeInterval = 0

    /// The RoboFrame slideshow server this mode talks to. Linked from the
    /// Remote tab so the endpoint field isn't the only clue about what's
    /// expected on the other end.
    static let roboFrameRepositoryURL = URL(string: "https://github.com/illixion/RoboFrame")!

    /// Selectable auto-refresh intervals. Index 0 is "off"; the Remote tab
    /// drives a slider over these indices rather than a linear seconds range,
    /// so both "every 15 seconds" and "every hour" are one gesture away.
    static let webAutoRefreshOptions: [TimeInterval] = [
        0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600
    ]

    /// Normalized page URL, or nil when the field is empty/unparseable. A
    /// scheme-less host gets `https://` so "example.com" just works.
    var resolvedWebPageURL: URL? {
        let trimmed = webPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    /// Human-readable label for an auto-refresh interval.
    static func webAutoRefreshLabel(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "Off" }
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

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

    /// A fresh profile carrying every setting of this one, under a new name.
    /// The Remote tab's Copy button used to enumerate fields by hand and had
    /// silently drifted out of date (it dropped diorama, 3D mode and the
    /// resolution caps) — copying wholesale can't drift.
    func duplicated(name: String) -> RemoteViewerConfig {
        var copy = self
        copy.id = UUID()
        copy.savedDate = Date()
        copy.name = name
        return copy
    }

    /// Overwrite exactly the fields an open viewer window can change from its
    /// ornament and adjustments panel, leaving everything else alone.
    ///
    /// A window holds the profile as it was when it opened, so persisting that
    /// snapshot wholesale reverts anything the Remote tab saved in the
    /// meantime — a clock toggle would silently undo an endpoint edit. The
    /// window's write-back merges through here instead. Keep this list in sync
    /// with the `display*` setters on `RemoteViewerModel` plus the ornament's
    /// 3D-mode and resolution menus; a field nothing in the viewer mutates
    /// must stay out of it, or the stale snapshot leaks back in through it.
    mutating func applyViewerDisplaySettings(from source: RemoteViewerConfig) {
        delay = source.delay
        showClock = source.showClock
        showSensors = source.showSensors
        useAspectRatio = source.useAspectRatio
        enableKenBurns = source.enableKenBurns
        enableDynamicBrightness = source.enableDynamicBrightness
        enableDiorama = source.enableDiorama
        transparentBackground = source.transparentBackground
        slideshow3DMode = source.slideshow3DMode
        maxImageResolution2D = source.maxImageResolution2D
        maxImageResolution3D = source.maxImageResolution3D
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, savedDate, mode
        case apiEndpoint, wsDeviceId, accessToken
        case webPageURL, webTransparentBackground, webAutoRefreshInterval
        case delay, showClock, showSensors, useAspectRatio, enableKenBurns
        case enableDynamicBrightness, enableDiorama
        case transparentBackground, textSize
        case slideshow3DMode, maxImageResolution2D, maxImageResolution3D
        // Decoded silently from older saved configs and never re-encoded.
        case wsEndpoint
        case homeAssistantURL
        case blockedPosts, blockedTags
        // The tag list (catalog, selection, recovery hint) is fully
        // server-tracked now — the RoboFrame backend persists each channel's
        // current list, so nothing about it is stored per-profile.
        case tagLists, defaultTagListIndex, lastActiveTagListIndex, tagListIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedDate = try container.decode(Date.self, forKey: .savedDate)
        mode = try container.decodeIfPresent(RemoteViewerMode.self, forKey: .mode) ?? .slideshow

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

        webPageURL = try container.decodeIfPresent(String.self, forKey: .webPageURL) ?? ""
        webTransparentBackground = try container.decodeIfPresent(Bool.self, forKey: .webTransparentBackground) ?? false
        webAutoRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .webAutoRefreshInterval) ?? 0

        // Older saved configs may carry these fields. Swallow them so the
        // decode succeeds and they're dropped on next save — the server
        // is now authoritative on tag and blocked lists, the WS URL is
        // always derived from `apiEndpoint`, and the Home Assistant
        // overlay was removed.
        _ = try container.decodeIfPresent(String.self, forKey: .wsEndpoint)
        _ = try container.decodeIfPresent(String.self, forKey: .homeAssistantURL)
        _ = try container.decodeIfPresent([Int].self, forKey: .blockedPosts)
        _ = try container.decodeIfPresent([String].self, forKey: .blockedTags)
        _ = try container.decodeIfPresent([[String]].self, forKey: .tagLists)
        _ = try container.decodeIfPresent(Int.self, forKey: .defaultTagListIndex)
        _ = try container.decodeIfPresent(Int.self, forKey: .lastActiveTagListIndex)
        _ = try container.decodeIfPresent(Int.self, forKey: .tagListIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(savedDate, forKey: .savedDate)
        try container.encode(mode, forKey: .mode)

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

        try container.encode(webPageURL, forKey: .webPageURL)
        try container.encode(webTransparentBackground, forKey: .webTransparentBackground)
        try container.encode(webAutoRefreshInterval, forKey: .webAutoRefreshInterval)
    }
}
