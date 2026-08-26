/*
 Spatial Stash - Photos Album Catalog

 Enumerates the albums offered by the Photos filter: the user's own albums, plus
 a curated set of system smart albums.

 This is the photo-library answer to Stash's galleries — the same filter
 dimension, populated from a different place. It is deliberately a *filter*
 dimension rather than a browser: one album at a time, because that is the only
 shape PhotoKit fetches in.

 Curated rather than exhaustive. `PHAssetCollectionSubtype` lists a couple of
 dozen smart albums, several of which are either empty on this platform or
 duplicate the Kind filter exactly (Panoramas, Screenshots). The ones here are
 those a spatial-photo app has a reason to jump to.

 Counts are per media type, which is why an album can appear in the Pictures
 filter and not in the Videos one — and why an album with nothing of the current
 kind is dropped instead of offered as a dead end.
 */

import Foundation
import Photos

enum PhotosAlbumCatalog {

    /// Smart albums worth offering, in the order they are shown.
    private static let smartAlbumSubtypes: [PHAssetCollectionSubtype] = [
        .smartAlbumFavorites,
        .smartAlbumSpatial,
        .smartAlbumRecentlyAdded,
        .smartAlbumDepthEffect,
        .smartAlbumLivePhotos,
        .smartAlbumPanoramas,
        .smartAlbumBursts,
        .smartAlbumScreenshots,
        .smartAlbumSelfPortraits,
        .smartAlbumSlomoVideos,
        .smartAlbumTimelapses,
        .smartAlbumCinematic,
        .smartAlbumAnimated,
        .smartAlbumLongExposures,
        .smartAlbumRAW,
        .smartAlbumScreenRecordings,
    ]

    /// Every album containing at least one asset of `mediaType`.
    ///
    /// User albums first, then smart albums, mirroring how Photos itself orders
    /// them. Returns empty rather than partial results when the library cannot
    /// be read: an unreadable library has no albums to speak of, and the
    /// gallery is already explaining why.
    static func albums(for mediaType: PHAssetMediaType) -> [PhotoAlbum] {
        guard PhotosAuthorization.isReadable else { return [] }

        var albums: [PhotoAlbum] = []

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            if let album = describe(collection, mediaType: mediaType, isSmart: false) {
                albums.append(album)
            }
        }
        albums.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for subtype in smartAlbumSubtypes {
            let fetched = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            guard let collection = fetched.firstObject,
                  let album = describe(collection, mediaType: mediaType, isSmart: true) else { continue }
            albums.append(album)
        }

        return albums
    }

    /// The album's name and count, or nil when it holds nothing of this type.
    private static func describe(_ collection: PHAssetCollection,
                                 mediaType: PHAssetMediaType,
                                 isSmart: Bool) -> PhotoAlbum? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        // `estimatedAssetCount` is usually NSNotFound and never respects a
        // predicate, so the count has to come from a fetch. It is a counted
        // fetch against an indexed column, not a materialization.
        let count = PHAsset.fetchAssets(in: collection, options: options).count
        guard count > 0 else { return nil }

        let name = collection.localizedTitle ?? (isSmart ? "Album" : "Untitled Album")
        return PhotoAlbum(id: collection.localIdentifier, name: name, isSmart: isSmart, count: count)
    }
}
