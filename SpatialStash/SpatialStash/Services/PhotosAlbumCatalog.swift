/*
 Spatial Stash - Photos Album Catalog

 Enumerates the albums the index should mirror: the user's own albums, plus a
 curated set of system smart albums.

 This is the photo-library answer to Stash's galleries — the same filter
 dimension, populated from a different place.

 Curated rather than exhaustive. `PHAssetCollectionSubtype` lists a couple of
 dozen smart albums, several of which are either empty on this platform or
 duplicate the Kind filter exactly. The ones here are those a spatial-photo app
 has a reason to jump to.

 Counting is deliberately *not* done here. It used to be, one `PHAsset` fetch per
 album per media type, every time the Filters tab appeared. Membership is now
 indexed, so counts come from a single grouped query in `PhotosIndexStore`.
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

    /// Every collection to index, user albums first then smart albums, mirroring
    /// how Photos itself orders them. The array order becomes the album's
    /// `sort_order` in the index, so the picker shows them the same way.
    static func collections() -> [PHAssetCollection] {
        guard PhotosAuthorization.isReadable else { return [] }

        var userAlbums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in userAlbums.append(collection) }
        userAlbums.sort {
            ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending
        }

        var smartAlbums: [PHAssetCollection] = []
        for subtype in smartAlbumSubtypes {
            let fetched = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            if let collection = fetched.firstObject {
                smartAlbums.append(collection)
            }
        }

        return userAlbums + smartAlbums
    }
}
