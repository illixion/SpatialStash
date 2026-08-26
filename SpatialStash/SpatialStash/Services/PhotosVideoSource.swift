/*
 Spatial Stash - Photos Video Source

 `VideoSource` over the device photo library, answered from `PhotosIndexStore`.
 Mirrors `PhotosImageSource`; only the mapping differs.

 What differs about videos is what the URL has to survive: an image is decoded to
 bytes, but a video is handed to AVPlayer, which needs something it can open. So
 `streamURL` carries the synthetic `photos-asset:///` URL as identity, and
 `VideoWindowModel` resolves it to a playable URL once per video before the
 renderer is probed. The playable URL is never stored on the model, because it is
 valid for one launch only — the identity is what persists, and it is what the
 depth cache and 3D settings key on.

 There is no `transcodeStreamURL`: that is a Stash server concept, and a local
 asset has no server to transcode it. AVFoundation decodes everything the camera
 produces, so the WebKit fallback is not needed either.
 */

import AVFoundation
import Foundation
import Photos

final class PhotosVideoSource: VideoSource, @unchecked Sendable {

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        let criteria = filter?.photosCriteria ?? PhotosFilterCriteria()
        // Nil leaves the filter off entirely; an empty array means it is on and
        // nothing qualifies, which the query renders as "match nothing" rather
        // than as an unconstrained search.
        let converted = filter?.showsOnlyConverted == true
            ? await ConvertedMediaRegistry.photosAssetIdentifiers(isVideo: true)
            : nil

        let result = try await PhotosIndexStore.shared.page(criteria: criteria,
                                                           mediaType: .video,
                                                           page: page,
                                                           pageSize: pageSize,
                                                           convertedIdentifiers: converted)

        var videos: [GalleryVideo] = []
        videos.reserveCapacity(result.assets.count)
        for asset in result.assets {
            guard let url = PhotosAssetURL.url(forLocalIdentifier: asset.id) else { continue }
            let name = asset.displayFilename
            videos.append(
                GalleryVideo(
                    identity: url.absoluteString,
                    // No stashId: there is no scene on any server behind this,
                    // so rating, o-counter and destroy correctly stay unavailable.
                    thumbnailURL: url,
                    streamURL: url,
                    title: name,
                    duration: asset.duration,
                    sourceWidth: asset.width,
                    sourceHeight: asset.height,
                    fileName: name
                )
            )
        }

        let shown = (page * pageSize) + result.assets.count
        return VideoFetchResult(videos: videos, hasMore: shown < result.total, totalCount: result.total)
    }
}
