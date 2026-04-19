/*
 Spatial Stash - Settings Backup

 Codable backup container for all app settings plus a lightweight FileDocument
 wrapper for SwiftUI fileExporter / fileImporter.
 */

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup Data Model

struct SettingsBackup: Codable {
    /// Schema version — increment when fields change semantics or type.
    let version: Int
    let exportDate: Date
    let appVersion: String

    // Simple display settings (all optional for forward/backward compatibility)
    var stashServerURL: String?
    var stashAPIKey: String?
    var autoHideDelay: TimeInterval?
    var slideshowDelay: TimeInterval?
    var maxImageResolution: Int?
    var roundedCorners: Bool?
    var openMediaInNewWindows: Bool?
    /// Legacy key for backward compatibility when importing old backups
    var openImagesInSeparateWindows: Bool?
    var rememberImageEnhancements: Bool?
    var autoRestoreSpatial3D: Bool?
    var showDebugConsole: Bool?
    var respectMemoryAlerts: Bool?
    var enableRemoteViewer: Bool?

    // Complex Codable settings
    var savedViews: [SavedView]?
    var savedVideoViews: [SavedVideoView]?
    var savedWindowGroups: [SavedWindowGroup]?
    var savedRemoteConfigs: [RemoteViewerConfig]?

    // Tag lists (shared across all viewer windows)
    var tagLists: [[String]]?
    var tagListDefaultIndex: Int?
    var tagListLastActiveIndex: Int?

    // Actor-based tracker data
    var video3DSettings: [String: Video3DSettings]?
    var imageEnhancementConvertedURLs: [String]?
    var imageEnhancementLastViewingModes: [String: String]?
    var imageEnhancementFlippedURLs: [String]?
    var imageEnhancementResolutionOverrides: [String: Int]?
    var imageEnhancementWindowSizes: [String: [Double]]?

    // Visual adjustments
    var globalVisualAdjustments: Data?
    var imageEnhancementAdjustments: [String: Data]?

    static let currentVersion = 1
}

// MARK: - FileDocument Wrapper

struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
