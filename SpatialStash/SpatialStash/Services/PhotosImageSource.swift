/*
 Spatial Stash - Photos Image Source

 `ImageSource` over the device photo library.

 Only the mapping from `PHAsset` to `GalleryImage` lives here. Paging, the fetch
 snapshot, the authorization guard and the seeded shuffle are `PhotosAssetPager`,
 shared with `PhotosVideoSource`.

 The `filter` argument arrives as Stash-shaped criteria, of which exactly one
 part applies: `photosCriteria`. Album scoping rides in there rather than being
 fixed at construction, so a filter change needs no new source — which is what
 keeps the Filters tab's "apply on leave" working for Photos the same way it
 works for Stash.
 */

import Foundation
import Photos

final class PhotosImageSource: ImageSource, @unchecked Sendable {

    private let pager = PhotosAssetPager(mediaType: .image)

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        try await fetchImages(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        let result = pager.page(page, pageSize: pageSize, criteria: filter?.photosCriteria ?? PhotosFilterCriteria())

        var images: [GalleryImage] = []
        images.reserveCapacity(result.assets.count)
        for asset in result.assets {
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

        return ImageFetchResult(images: images, hasMore: result.hasMore, totalCount: result.total)
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
