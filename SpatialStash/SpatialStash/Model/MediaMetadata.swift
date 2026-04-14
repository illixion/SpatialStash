/*
 Spatial Stash - Media Metadata Models

 Lightweight structs for tags, performers, studios, galleries, and groups
 used in the detail/edit views. Fetched on-demand, not in list queries.
 */

import Foundation

struct MediaTag: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

struct MediaPerformer: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

struct MediaStudio: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

struct MediaGalleryRef: Identifiable, Codable, Hashable {
    let id: String
    let title: String?
}

struct MediaGroupRef: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

// MARK: - Image Detail (on-demand metadata)

/// Full metadata for an image, fetched on-demand when the info sheet opens.
struct ImageDetail {
    let id: String
    var title: String?
    var code: String?
    var date: String?
    var details: String?
    var photographer: String?
    var rating100: Int?
    var oCounter: Int?
    var organized: Bool
    var urls: [String]

    // File info
    let filePath: String?
    let fileSize: Int64?
    let format: String?
    let width: Int?
    let height: Int?

    // Associations
    var studio: MediaStudio?
    var performers: [MediaPerformer]
    var tags: [MediaTag]
    var galleries: [MediaGalleryRef]

    let createdAt: String?
    let updatedAt: String?
}

// MARK: - Scene/Video Detail (on-demand metadata)

/// Full metadata for a scene/video, fetched on-demand when the info sheet opens.
struct SceneDetail {
    let id: String
    var title: String?
    var code: String?
    var date: String?
    var details: String?
    var director: String?
    var rating100: Int?
    var oCounter: Int?
    var organized: Bool
    var urls: [String]

    // File info
    let filePath: String?
    let fileSize: Int64?
    let format: String?
    let width: Int?
    let height: Int?
    let duration: Double?
    let videoCodec: String?
    let audioCodec: String?
    let frameRate: Double?
    let bitrate: Int?

    // Associations
    var studio: MediaStudio?
    var performers: [MediaPerformer]
    var tags: [MediaTag]
    var galleries: [MediaGalleryRef]
    var groups: [MediaGroupRef]

    // Stats
    let playCount: Int?
    let playDuration: Double?

    let createdAt: String?
    let updatedAt: String?
}
