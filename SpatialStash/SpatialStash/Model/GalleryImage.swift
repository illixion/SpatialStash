/*
 Spatial Stash - Gallery Image Model

 Represents an image in the gallery with thumbnail and full-size URLs.
 */

import Foundation

struct GalleryImage: Identifiable, Equatable, Hashable {
    let id: UUID
    let stashId: String?
    let thumbnailURL: URL
    let fullSizeURL: URL
    let title: String?
    var rating100: Int?
    var oCounter: Int?
    /// Source of the image: "stash" or "local"
    let source: String
    /// Original filename from server (e.g. from visual_files path), used for sharing
    let fileName: String?

    init(id: UUID = UUID(), stashId: String? = nil, thumbnailURL: URL, fullSizeURL: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: String = "stash", fileName: String? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.fullSizeURL = fullSizeURL
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
    }

    /// Convenience initializer when thumbnail and full-size are the same URL
    init(id: UUID = UUID(), stashId: String? = nil, url: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: String = "stash", fileName: String? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = url
        self.fullSizeURL = url
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
    }
}

// MARK: - Codable with Backward Compatibility

extension GalleryImage: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case stashId
        case thumbnailURL
        case fullSizeURL
        case title
        case rating100
        case oCounter
        case source
        case fileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        stashId = try container.decodeIfPresent(String.self, forKey: .stashId)
        thumbnailURL = try container.decode(URL.self, forKey: .thumbnailURL)
        fullSizeURL = try container.decode(URL.self, forKey: .fullSizeURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        rating100 = try container.decodeIfPresent(Int.self, forKey: .rating100)
        oCounter = try container.decodeIfPresent(Int.self, forKey: .oCounter)

        // Default to "stash" for backward compatibility with old saved window groups
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "stash"
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(stashId, forKey: .stashId)
        try container.encode(thumbnailURL, forKey: .thumbnailURL)
        try container.encode(fullSizeURL, forKey: .fullSizeURL)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(rating100, forKey: .rating100)
        try container.encodeIfPresent(oCounter, forKey: .oCounter)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
}

