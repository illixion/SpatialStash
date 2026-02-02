import Foundation
import os

/// Centralized logging facility for SpatialStash
/// Uses Apple's os.Logger API for structured, performant logging
enum AppLogger {
    /// App bundle identifier used as the logging subsystem
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.spatial-stash"

    // MARK: - Logger Categories

    /// AppModel state and navigation logging
    static let appModel = Logger(subsystem: subsystem, category: "AppModel")

    /// Stash GraphQL API client logging
    static let stashAPI = Logger(subsystem: subsystem, category: "StashAPI")

    /// Disk image cache operations
    static let diskCache = Logger(subsystem: subsystem, category: "DiskCache")

    /// Disk video cache operations
    static let videoCache = Logger(subsystem: subsystem, category: "VideoCache")

    /// Spatial 3D conversion tracking
    static let spatial3DTracker = Logger(subsystem: subsystem, category: "Spatial3DTracker")

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
}
