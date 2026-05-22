import Foundation
import os

/// Centralized logging facility for SpatialStash
/// Uses Apple's os.Logger API for structured, performant logging.
///
/// **Debug visibility note:** `os.Logger.debug(...)` entries are not
/// preserved by OSLogStore on visionOS — they live only in the in-memory
/// ring buffer, so they don't show up in the in-app debug console even
/// when the level filter is set to Debug. Call sites that want their
/// entries visible in the console should use `Logger.log(level:_:)` with
/// `effectiveDebugLevel` so the level is promoted to `.info` while a
/// console window is open and stays `.debug` otherwise.
///
/// Example:
/// ```
/// AppLogger.remoteViewer.log(level: AppLogger.effectiveDebugLevel,
///                            "post \(id, privacy: .public)")
/// ```
///
/// `OSLogMessage` is a compiler-special type that cannot be passed
/// through wrapper functions, which forces this call-site pattern rather
/// than a custom Logger subtype.
enum AppLogger {
    /// App bundle identifier used as the logging subsystem
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.spatial-stash"

    /// `.info` while at least one console viewer is registered, `.debug`
    /// otherwise. Cheap to read (single unfair-lock-protected Bool).
    /// Pass this to `Logger.log(level:_:)` for entries that should be
    /// visible in the in-app debug console.
    static var effectiveDebugLevel: OSLogType {
        LogStore.hasActiveViewers ? .info : .debug
    }

    // MARK: - Logger Categories

    /// AppModel state and navigation logging
    static let appModel = Logger(subsystem: subsystem, category: "AppModel")

    /// Stash GraphQL API client logging
    static let stashAPI = Logger(subsystem: subsystem, category: "StashAPI")

    /// Disk image cache operations
    static let diskCache = Logger(subsystem: subsystem, category: "DiskCache")

    /// Disk video cache operations
    static let videoCache = Logger(subsystem: subsystem, category: "VideoCache")

    /// Image enhancement tracking (3D conversion, background removal)
    static let enhancementTracker = Logger(subsystem: subsystem, category: "EnhancementTracker")

    /// Photo window model (per-window image state)
    static let photoWindow = Logger(subsystem: subsystem, category: "PhotoWindow")

    /// Local media source scanning
    static let localMedia = Logger(subsystem: subsystem, category: "LocalMedia")

    /// GraphQL image source
    static let graphQLImage = Logger(subsystem: subsystem, category: "GraphQLImageSource")

    /// GraphQL video source
    static let graphQLVideo = Logger(subsystem: subsystem, category: "GraphQLVideoSource")

    /// Stereoscopic video player
    static let stereoscopicPlayer = Logger(subsystem: subsystem, category: "StereoscopicPlayer")

    /// Image loader and caching
    static let imageLoader = Logger(subsystem: subsystem, category: "ImageLoader")

    /// UI/View layer logging
    static let views = Logger(subsystem: subsystem, category: "Views")

    /// Settings operations
    static let settings = Logger(subsystem: subsystem, category: "Settings")

    /// Immersive video view
    static let immersiveVideo = Logger(subsystem: subsystem, category: "ImmersiveVideo")

    /// General app lifecycle
    static let app = Logger(subsystem: subsystem, category: "App")

    /// Shared media handling (share sheet, caching, saving)
    static let sharedMedia = Logger(subsystem: subsystem, category: "SharedMedia")

    /// Window state persistence and restoration
    static let windowState = Logger(subsystem: subsystem, category: "WindowState")

    /// Background removal processing
    static let backgroundRemover = Logger(subsystem: subsystem, category: "BackgroundRemover")

    /// GIF to HEVC conversion and caching
    static let gifConverter = Logger(subsystem: subsystem, category: "GIFConverter")

    /// Video window model (per-window video state)
    static let videoWindow = Logger(subsystem: subsystem, category: "VideoWindow")

    /// Window visibility heartbeat diagnostics
    static let visibilityProbe = Logger(subsystem: subsystem, category: "VisibilityProbe")

    /// Visual adjustments (brightness, contrast, saturation)
    static let visualAdjustments = Logger(subsystem: subsystem, category: "VisualAdjustments")

    /// Remote API viewer (slideshow, WebSocket, API)
    static let remoteViewer = Logger(subsystem: subsystem, category: "RemoteViewer")
}
