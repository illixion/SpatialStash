/*
 Spatial Stash - Photos Filter

 Filter criteria for the device photo library, and the single place they are
 translated into a `PHFetchOptions`.

 The Stash criteria (`ImageFilterCriteria` / `SceneFilterCriteria`) describe a
 server's data model — tags, performers, studios, ratings, o-count — and none of
 it exists in PhotoKit. Rather than half-apply those, the photo library gets its
 own criteria describing what PhotoKit can actually answer, and the Filters tab
 shows whichever set belongs to the library in force.

 What PhotoKit can answer is a short list, and it is short for a reason:
 `PHFetchOptions.predicate` accepts only a documented subset of keys, and
 filename is not among them. So there is no "search titles" here — matching a
 name would mean walking every asset and asking `PHAssetResource` for its
 filename, which is a per-asset round trip over the whole library. The
 alternative to an honest omission would be a search box that quietly costs
 seconds and breaks pagination.

 Attached to both criteria structs as an *optional* property. That matters:
 synthesized `Codable` decodes an optional with `decodeIfPresent`, so saved
 views written before this existed still decode. A non-optional with a default
 would have required the key and thrown, and `loadSavedViews` decodes the whole
 array under one `try?` — one old view would have wiped every saved view.
 */

import Foundation
import Photos

// MARK: - Sort Field

enum PhotosSortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case dateAdded = "creationDate"
    case dateModified = "modificationDate"
    /// The album's own manual order, which PhotoKit only surrenders when no
    /// sort descriptor is set at all. Means library order outside an album.
    case albumOrder = "albumOrder"
    case random = "random"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .albumOrder: return "Album Order"
        case .random: return "Random"
        }
    }

    /// The `PHFetchOptions` sort key, or nil to leave the order to PhotoKit.
    ///
    /// Random still sorts by date: the shuffle is a permutation applied on top,
    /// and it can only be reproduced across pages if the order it permutes is
    /// itself stable.
    var sortKey: String? {
        switch self {
        case .dateAdded, .random: return "creationDate"
        case .dateModified: return "modificationDate"
        case .albumOrder: return nil
        }
    }

    /// Whether the direction picker means anything for this field.
    var isDirectional: Bool {
        self == .dateAdded || self == .dateModified
    }
}

// MARK: - Media Kind

/// A media subtype worth filtering on, named as the user would name it.
///
/// Each case maps to exactly one `PHAssetMediaSubtype`, so nothing here is
/// synthesized client-side. Notably absent is a separate slo-mo case: PhotoKit
/// records slo-mo as `videoHighFrameRate` and has no distinct subtype for it.
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
}

// MARK: - Criteria

struct PhotosFilterCriteria: Codable, Equatable, Sendable {
    /// `PHAssetCollection.localIdentifier`, or nil for the whole library.
    var albumId: String?
    /// Kept alongside the id so the picker can label the current selection
    /// without a fetch, and so a saved view still reads sensibly if the album
    /// has since been deleted.
    var albumName: String?
    var favoritesOnly: Bool = false
    var kind: PhotosMediaKind = .any
    var dateRangeEnabled: Bool = false
    var startDate: Date?
    var endDate: Date?
    var sortField: PhotosSortField = .dateAdded
    var sortDirection: SortDirection = .descending
    var randomSeed: Int?

    init() {}

    var hasActiveFilters: Bool {
        albumId != nil || favoritesOnly || kind != .any || dateRangeEnabled
    }

    mutating func clearFilters() {
        albumId = nil
        albumName = nil
        favoritesOnly = false
        kind = .any
        dateRangeEnabled = false
        startDate = nil
        endDate = nil
    }

    mutating func shuffleRandomSort() {
        randomSeed = Int.random(in: 10_000_000..<100_000_000)
    }

    /// Drops a kind that does not apply to `mediaType`.
    ///
    /// The two tabs share one set of kinds, so switching from Pictures to Videos
    /// with "Panorama" selected would otherwise hand PhotoKit a predicate that
    /// nothing can match and report an empty library.
    func normalized(for mediaType: PHAssetMediaType) -> PhotosFilterCriteria {
        guard !kind.applies(to: mediaType) else { return self }
        var copy = self
        copy.kind = .any
        return copy
    }

    // MARK: PhotoKit translation

    /// The album this filter is scoped to, or nil for the whole library.
    ///
    /// Returns nil for an album that no longer resolves — deleted, or dropped
    /// from a `.limited` selection — which correctly widens to the library
    /// rather than reporting nothing at all.
    func resolvedCollection() -> PHAssetCollection? {
        guard let albumId else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject
    }

    /// The one translation into PhotoKit's vocabulary, shared by both sources.
    func fetchOptions(for mediaType: PHAssetMediaType) -> PHFetchOptions {
        let options = PHFetchOptions()

        var predicates = [NSPredicate(format: "mediaType == %d", mediaType.rawValue)]
        if favoritesOnly {
            predicates.append(NSPredicate(format: "favorite == YES"))
        }
        if let subtype = kind.subtype, kind.applies(to: mediaType) {
            predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue))
        }
        if dateRangeEnabled {
            if let startDate {
                predicates.append(NSPredicate(format: "creationDate >= %@", startDate as NSDate))
            }
            if let endDate {
                predicates.append(NSPredicate(format: "creationDate <= %@", endDate as NSDate))
            }
        }
        options.predicate = predicates.count == 1
            ? predicates[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        if let key = sortField.sortKey {
            let ascending = sortField.isDirectional ? sortDirection == .ascending : false
            options.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        }
        return options
    }
}

// MARK: - Codable

/*
 Hand-written so an unrecognised enum value degrades to the default instead of
 throwing. `decodeIfPresent` on a `RawRepresentable` only returns nil for a
 missing or null key — a *present but unrecognised* raw value throws, and one
 throw here would take down the entire saved-views array.
 */
extension PhotosFilterCriteria {
    private enum CodingKeys: String, CodingKey {
        case albumId, albumName, favoritesOnly, kind, dateRangeEnabled
        case startDate, endDate, sortField, sortDirection, randomSeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        albumId = try container.decodeIfPresent(String.self, forKey: .albumId)
        albumName = try container.decodeIfPresent(String.self, forKey: .albumName)
        favoritesOnly = try container.decodeIfPresent(Bool.self, forKey: .favoritesOnly) ?? false
        dateRangeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dateRangeEnabled) ?? false
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        randomSeed = try container.decodeIfPresent(Int.self, forKey: .randomSeed)

        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(PhotosMediaKind.init(rawValue:)) ?? .any
        let rawSort = try container.decodeIfPresent(String.self, forKey: .sortField)
        sortField = rawSort.flatMap(PhotosSortField.init(rawValue:)) ?? .dateAdded
        let rawDirection = try container.decodeIfPresent(String.self, forKey: .sortDirection)
        sortDirection = rawDirection.flatMap(SortDirection.init(rawValue:)) ?? .descending
    }
}
