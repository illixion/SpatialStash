/*
 Spatial Stash - Photos Filter

 Filter criteria for the device photo library.

 The Stash criteria (`ImageFilterCriteria` / `SceneFilterCriteria`) describe a
 server's data model — tags, performers, studios, ratings — and none of it exists
 in PhotoKit. So the photo library gets its own criteria, and the Filters tab
 shows whichever set belongs to the library in force.

 These are answered by `PhotosIndexStore`, not by `PHFetchOptions`, and that is
 what makes half of them possible at all: `PHFetchOptions.predicate` accepts a
 fixed set of keys, filename is not one of them, and `fetchAssets(in:)` takes a
 single collection. Filename search, multi-select albums and multi-select people
 have no expression in PhotoKit at any cost.

 Attached to both criteria structs as an *optional* property. That matters:
 synthesized `Codable` decodes an optional with `decodeIfPresent`, so saved views
 written before this existed still decode. A non-optional with a default would
 have required the key and thrown, and `loadSavedViews` decodes the whole array
 under one `try?` — one old view would have wiped every saved view.
 */

import Foundation
import Photos

// MARK: - Sort Field

enum PhotosSortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case dateAdded = "creationDate"
    case dateModified = "modificationDate"
    case filename = "filename"
    /// The album's own manual order. Only meaningful with exactly one album
    /// selected; the query falls back to library order otherwise.
    case albumOrder = "albumOrder"
    case random = "random"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .filename: return "Name"
        case .albumOrder: return "Album Order"
        case .random: return "Random"
        }
    }

    /// Whether the direction picker means anything for this field.
    var isDirectional: Bool {
        self != .random
    }
}

// MARK: - Media Kind

/// A media subtype worth filtering on, named as the user would name it.
///
/// Each case maps to exactly one `PHAssetMediaSubtype`, so nothing here is
/// synthesized. Notably absent is a separate slo-mo case: PhotoKit records
/// slo-mo as `videoHighFrameRate` and has no distinct subtype for it.
enum PhotosMediaKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case spatial
    case panorama
    case screenshot
    case livePhoto
    case portrait
    case hdr
    case highFrameRate
    case timelapse
    case cinematic
    case screenRecording

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "Any"
        case .spatial: return "Spatial"
        case .panorama: return "Panorama"
        case .screenshot: return "Screenshot"
        case .livePhoto: return "Live Photo"
        case .portrait: return "Portrait"
        case .hdr: return "HDR"
        case .highFrameRate: return "Slo-mo & High Frame Rate"
        case .timelapse: return "Time-lapse"
        case .cinematic: return "Cinematic"
        case .screenRecording: return "Screen Recording"
        }
    }

    var subtype: PHAssetMediaSubtype? {
        switch self {
        case .any: return nil
        case .spatial: return .spatialMedia
        case .panorama: return .photoPanorama
        case .screenshot: return .photoScreenshot
        case .livePhoto: return .photoLive
        case .portrait: return .photoDepthEffect
        case .hdr: return .photoHDR
        case .highFrameRate: return .videoHighFrameRate
        case .timelapse: return .videoTimelapse
        case .cinematic: return .videoCinematic
        case .screenRecording: return .videoScreenRecording
        }
    }

    func applies(to mediaType: PHAssetMediaType) -> Bool {
        switch self {
        case .any, .spatial:
            return true
        case .panorama, .screenshot, .livePhoto, .portrait, .hdr:
            return mediaType == .image
        case .highFrameRate, .timelapse, .cinematic, .screenRecording:
            return mediaType == .video
        }
    }

    /// The kinds offered for one media type, `.any` first.
    static func options(for mediaType: PHAssetMediaType) -> [PhotosMediaKind] {
        allCases.filter { $0.applies(to: mediaType) }
    }
}

// MARK: - Album

/// One selectable container: a user album or a system smart album.
///
/// `count` is for the media type being filtered, which is why an album can
/// appear in the Pictures filter and not the Videos one.
struct PhotoAlbum: Identifiable, Hashable, Codable, Sendable {
    /// `PHAssetCollection.localIdentifier`.
    let id: String
    let name: String
    let isSmart: Bool
    let count: Int
    /// First asset of the filtered media type, for the chip's thumbnail.
    let keyAssetId: String?
}

// MARK: - Criteria

struct PhotosFilterCriteria: Codable, Equatable, Sendable {
    /// Matched against the filename, case-insensitively, anywhere in the name.
    var searchTerm: String = ""

    /// Albums, stored with their names so a chip can label itself without a
    /// catalog lookup — the same shape the Stash filters use for galleries.
    var selectedAlbums: [AutocompleteItem] = []
    /// Defaults to "any of": picking two albums to see both albums' photos is
    /// the common reading. Photos' own People filter intersects, which is why
    /// people default the other way.
    var albumModifier: CriterionModifier = .includes

    var selectedPeople: [AutocompleteItem] = []
    var personModifier: CriterionModifier = .includesAll

    var favoritesOnly: Bool = false
    var kind: PhotosMediaKind = .any

    /// Only items the app has already produced 3D output for. Resolved at query
    /// time from the depth cache and the enhancement tracker rather than stored.
    var onlyConverted: Bool = false

    var dateRangeEnabled: Bool = false
    var startDate: Date?
    var endDate: Date?

    var sortField: PhotosSortField = .dateAdded
    var sortDirection: SortDirection = .descending
    var randomSeed: Int?

    init() {}

    var albumIds: [String] { selectedAlbums.map(\.id) }
    var personIds: [String] { selectedPeople.map(\.id) }

    var hasActiveFilters: Bool {
        !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !selectedAlbums.isEmpty ||
        !selectedPeople.isEmpty ||
        favoritesOnly ||
        kind != .any ||
        onlyConverted ||
        dateRangeEnabled
    }

    mutating func clearFilters() {
        searchTerm = ""
        selectedAlbums = []
        albumModifier = .includes
        selectedPeople = []
        personModifier = .includesAll
        favoritesOnly = false
        kind = .any
        onlyConverted = false
        dateRangeEnabled = false
        startDate = nil
        endDate = nil
    }

    mutating func shuffleRandomSort() {
        randomSeed = Int.random(in: 10_000_000..<100_000_000)
    }
}

// MARK: - Codable

/*
 Hand-written for two reasons.

 An unrecognised enum value degrades to the default instead of throwing:
 `decodeIfPresent` on a `RawRepresentable` only returns nil for a missing or null
 key — a *present but unrecognised* raw value throws, and one throw here would
 take down the entire saved-views array.

 And the single-album `albumId`/`albumName` pair this shipped with is migrated
 into `selectedAlbums`, so a saved view from that version keeps its album.
 */
extension PhotosFilterCriteria {
    private enum CodingKeys: String, CodingKey {
        case searchTerm, selectedAlbums, albumModifier, selectedPeople, personModifier
        case favoritesOnly, kind, onlyConverted, dateRangeEnabled
        case startDate, endDate, sortField, sortDirection, randomSeed
        // Retired single-select album, read for migration only.
        case albumId, albumName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()

        searchTerm = try container.decodeIfPresent(String.self, forKey: .searchTerm) ?? ""
        favoritesOnly = try container.decodeIfPresent(Bool.self, forKey: .favoritesOnly) ?? false
        onlyConverted = try container.decodeIfPresent(Bool.self, forKey: .onlyConverted) ?? false
        dateRangeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dateRangeEnabled) ?? false
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        randomSeed = try container.decodeIfPresent(Int.self, forKey: .randomSeed)

        selectedAlbums = try container.decodeIfPresent([AutocompleteItem].self, forKey: .selectedAlbums) ?? []
        selectedPeople = try container.decodeIfPresent([AutocompleteItem].self, forKey: .selectedPeople) ?? []

        if selectedAlbums.isEmpty,
           let legacyId = try container.decodeIfPresent(String.self, forKey: .albumId) {
            let name = try container.decodeIfPresent(String.self, forKey: .albumName) ?? "Album"
            selectedAlbums = [AutocompleteItem(id: legacyId, name: name)]
        }

        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(PhotosMediaKind.init(rawValue:)) ?? .any
        let rawSort = try container.decodeIfPresent(String.self, forKey: .sortField)
        sortField = rawSort.flatMap(PhotosSortField.init(rawValue:)) ?? .dateAdded
        let rawDirection = try container.decodeIfPresent(String.self, forKey: .sortDirection)
        sortDirection = rawDirection.flatMap(SortDirection.init(rawValue:)) ?? .descending
        let rawAlbumModifier = try container.decodeIfPresent(String.self, forKey: .albumModifier)
        albumModifier = rawAlbumModifier.flatMap(CriterionModifier.init(rawValue:)) ?? .includes
        let rawPersonModifier = try container.decodeIfPresent(String.self, forKey: .personModifier)
        personModifier = rawPersonModifier.flatMap(CriterionModifier.init(rawValue:)) ?? .includesAll
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchTerm, forKey: .searchTerm)
        try container.encode(selectedAlbums, forKey: .selectedAlbums)
        try container.encode(albumModifier, forKey: .albumModifier)
        try container.encode(selectedPeople, forKey: .selectedPeople)
        try container.encode(personModifier, forKey: .personModifier)
        try container.encode(favoritesOnly, forKey: .favoritesOnly)
        try container.encode(kind, forKey: .kind)
        try container.encode(onlyConverted, forKey: .onlyConverted)
        try container.encode(dateRangeEnabled, forKey: .dateRangeEnabled)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(sortField, forKey: .sortField)
        try container.encode(sortDirection, forKey: .sortDirection)
        try container.encodeIfPresent(randomSeed, forKey: .randomSeed)
    }
}
