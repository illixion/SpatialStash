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
    /// Where this image came from.
    let source: MediaSource
    /// Original filename from server (e.g. from visual_files path), used for sharing
    let fileName: String?
    /// Stash visual file GraphQL typename (e.g. ImageFile, VideoFile)
    let visualFileType: String?
    /// Native pixel dimensions reported by the server (visual_files). Used to
    /// seed the quick look's aspect ratio before the real image loads, so the
    /// pop frame is correctly sized from the first frame instead of assuming
    /// the (possibly cropped) cell thumbnail's aspect.
    let sourceWidth: Int?
    let sourceHeight: Int?

    init(id: UUID = UUID(), stashId: String? = nil, thumbnailURL: URL, fullSizeURL: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: MediaSource = .stash, fileName: String? = nil, visualFileType: String? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.fullSizeURL = fullSizeURL
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
        self.visualFileType = visualFileType
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    /// Convenience initializer when thumbnail and full-size are the same URL
    init(id: UUID = UUID(), stashId: String? = nil, url: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil, source: MediaSource = .stash, fileName: String? = nil, visualFileType: String? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = url
        self.fullSizeURL = url
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
        self.source = source
        self.fileName = fileName
        self.visualFileType = visualFileType
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

// MARK: - Identity

extension GalleryImage {
    /// Stable, source-agnostic key for this image.
    ///
    /// Computed rather than stored, unlike `GalleryVideo.identity`: an image
    /// already carries everything needed to derive one, so there is no legacy
    /// field to migrate and nothing for a producer to get wrong. A Stash image
    /// keys on its scene id; a container file keys on its container-relative
    /// path, which survives the per-launch container UUID change.
    ///
    /// Note that `ImageEnhancementTracker` does *not* use this yet — it keys on
    /// the image URL, which is correct for every source that has a stable one.
    /// A `PHAsset` has no such URL, so adopting this is part of the Photos work.
    var identity: String {
        if let stashId, !stashId.isEmpty { return stashId }
        return MediaIdentity.persistentKey(for: fullSizeURL)
    }
}

// MARK: - Local File URL Re-resolution

extension GalleryImage {
    /// Returns a copy with file URLs re-resolved against the current Documents directory.
    /// On visionOS/iOS the app sandbox container UUID changes on every launch, so
    /// persisted absolute file URLs become stale. This extracts the relative path
    /// after "Documents/" and reconstructs it using the current container path.
    /// Returns self unchanged for non-local images or when the file can't be found.
    func resolvingLocalFileURL() -> GalleryImage {
        guard source.isContainerFile, fullSizeURL.isFileURL else { return self }

        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return self
        }

        // If the URL already points to a valid file, no fixup needed
        if FileManager.default.fileExists(atPath: fullSizeURL.path) { return self }

        let pathComponents = fullSizeURL.pathComponents
        guard let docIndex = pathComponents.lastIndex(of: "Documents"),
              docIndex + 1 < pathComponents.count else {
            return self
        }

        let relativeParts = pathComponents[(docIndex + 1)...]
        var resolvedURL = documentsDir
        for part in relativeParts {
            resolvedURL = resolvedURL.appendingPathComponent(part)
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return self }

        return GalleryImage(
            id: id,
            stashId: stashId,
            thumbnailURL: resolvedURL,
            fullSizeURL: resolvedURL,
            title: title,
            rating100: rating100,
            oCounter: oCounter,
            source: source,
            fileName: fileName,
            visualFileType: visualFileType,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
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
        case visualFileType
        case sourceWidth
        case sourceHeight
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

        // Default to .stash for backward compatibility with old saved window
        // groups. An unrecognised raw value degrades to .stash rather than
        // failing the whole decode and losing the window group.
        source = (try container.decodeIfPresent(MediaSource.self, forKey: .source)) ?? .stash
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        visualFileType = try container.decodeIfPresent(String.self, forKey: .visualFileType)
        sourceWidth = try container.decodeIfPresent(Int.self, forKey: .sourceWidth)
        sourceHeight = try container.decodeIfPresent(Int.self, forKey: .sourceHeight)
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
        try container.encodeIfPresent(visualFileType, forKey: .visualFileType)
        try container.encodeIfPresent(sourceWidth, forKey: .sourceWidth)
        try container.encodeIfPresent(sourceHeight, forKey: .sourceHeight)
    }
}

