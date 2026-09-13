/*
 Hypnos - Photos Image Source

 `ImageSource` over the device photo library, answered from `PhotosIndexStore`
 rather than from `PHFetchOptions`.

 That indirection is what makes the filter dimensions possible at all: filename
 is not a PhotoKit predicate key, `fetchAssets(in:)` takes a single collection,
 and there is no random sort descriptor. See `PhotosIndexQuery`.

 It also means a page costs one SQL query and materializes no `PHAsset` objects —
 the grid gets identifiers plus the dimensions it needs to lay out cells, and the
 synthetic `photos-asset:///` URL carries the identifier onward to whatever
 actually needs pixels.

 No authorization guard and no readiness guard. An unreadable or not-yet-indexed
 library is simply an empty table, and the gallery's state view reads the
 indexer's phase directly to say which of those it is — a guard here would only
 duplicate that decision.
 */

import Foundation
import Photos

final class PhotosImageSource: ImageSource, @unchecked Sendable {

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        try await fetchImages(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        let criteria = filter?.photosCriteria ?? PhotosFilterCriteria()
        // Nil leaves the filter off entirely; an empty array means it is on and
        // nothing qualifies, which the query renders as "match nothing" rather
        // than as an unconstrained search.
        let converted = filter?.showsOnlyConverted == true
            ? await ConvertedMediaRegistry.photosAssetIdentifiers(isVideo: false)
            : nil

        let result = try await PhotosIndexStore.shared.page(criteria: criteria,
                                                           mediaType: .image,
                                                           page: page,
                                                           pageSize: pageSize,
                                                           convertedIdentifiers: converted)

        var images: [GalleryImage] = []
        images.reserveCapacity(result.assets.count)
        for asset in result.assets {
            guard let url = PhotosAssetURL.url(forLocalIdentifier: asset.id) else { continue }
            let name = asset.displayFilename
            images.append(
                GalleryImage(
                    url: url,
                    title: name,
                    source: .photos,
                    fileName: name,
                    sourceWidth: asset.width,
                    sourceHeight: asset.height
                )
            )
        }

        let shown = (page * pageSize) + result.assets.count
        return ImageFetchResult(images: images, hasMore: shown < result.total, totalCount: result.total)
    }
}

// MARK: - Filename

extension PhotosIndexedAsset {
    /// The filename for display, or nil.
    ///
    /// The index stores an empty string to mean "asked, and Photos gave nothing"
    /// — a distinct state from NULL, which means the name pass has not reached
    /// this asset yet. Neither is a title worth showing.
    var displayFilename: String? {
        guard let filename, !filename.isEmpty else { return nil }
        return filename
    }
}

extension PHAsset {
    /// The asset's original filename, when Photos will surrender it.
    ///
    /// `PHAssetResource` is the only public route to this, and it is an XPC round
    /// trip per asset — which is the entire reason the index exists and why
    /// filenames are backfilled rather than gathered up front.
    var originalFilename: String? {
        PHAssetResource.assetResources(for: self)
            .first { $0.type == .photo || $0.type == .video }?
            .originalFilename
    }
}
