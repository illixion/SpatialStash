/*
 Spatial Stash - Photos Image Source

 `ImageSource` over the device photo library, optionally scoped to one album.

 Pagination reads out of a `PHFetchResult`, which is lazy — it holds indices,
 not assets — so a page is a slice, never a full-library materialization.

 The fetch result is snapshotted once per source instance rather than re-fetched
 per page. Paging over a live result would let an import or deletion shift every
 index mid-scroll, so the user would see duplicated or skipped photos with no
 way to tell why. A snapshot can go stale instead, which is the better failure:
 a deleted asset simply stops resolving and drops out at load time.
 */

import Foundation
import Photos

final class PhotosImageSource: ImageSource, @unchecked Sendable {

    /// Album to read, or nil for the whole library.
    private let collection: PHAssetCollection?
    private let lock = NSLock()
    private var cachedFetch: PHFetchResult<PHAsset>?

    init(collection: PHAssetCollection? = nil) {
        self.collection = collection
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        try await fetchImages(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        // Stash-shaped filters (tags, performers, ratings) have no analogue in
        // the photo library, so they are ignored rather than half-applied.
        guard PhotosAuthorization.isReadable else {
            throw ImageSourceError.noImagesAvailable
        }

        let assets = fetchResult()
        let total = assets.count
        let start = page * pageSize
        guard start < total else {
            return ImageFetchResult(images: [], hasMore: false, totalCount: total)
        }
        let end = min(start + pageSize, total)

        var images: [GalleryImage] = []
        images.reserveCapacity(end - start)
        for index in start..<end {
            let asset = assets.object(at: index)
            guard let url = PhotosAssetURL.url(forLocalIdentifier: asset.localIdentifier) else { continue }
            images.append(
                GalleryImage(
                    url: url,
                    title: asset.originalFilename,
                    source: .photos,
                    fileName: asset.originalFilename,
                    sourceWidth: asset.pixelWidth,
                    sourceHeight: asset.pixelHeight
                )
            )
        }

        return ImageFetchResult(images: images, hasMore: end < total, totalCount: total)
    }

    // MARK: - Fetch

    private func fetchResult() -> PHFetchResult<PHAsset> {
        lock.lock()
        defer { lock.unlock() }
        if let cachedFetch { return cachedFetch }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result: PHFetchResult<PHAsset>
        if let collection {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        cachedFetch = result
        return result
    }
}

// MARK: - Filename

extension PHAsset {
    /// The asset's original filename, when Photos will surrender it.
    ///
    /// `PHAssetResource` is the only public route to this; the value backs both
    /// the window title and the share sheet's suggested name.
    var originalFilename: String? {
        PHAssetResource.assetResources(for: self)
            .first { $0.type == .photo || $0.type == .video }?
            .originalFilename
    }
}
