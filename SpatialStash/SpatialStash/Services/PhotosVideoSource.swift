/*
 Spatial Stash - Photos Video Source

 `VideoSource` over the device photo library. Mirrors `PhotosImageSource`, and
 shares its paging with it through `PhotosAssetPager`.

 What differs is what the URL has to survive: an image is decoded to bytes, but a
 video is handed to AVPlayer, which needs something it can open. So `streamURL`
 carries the synthetic `photos-asset:///` URL as identity, and `VideoWindowModel`
 resolves it to a playable URL once per video before the renderer is probed. The
 playable URL is never stored on the model, because it is valid for one launch
 only — the identity is what persists, and it is what the depth cache and 3D
 settings key on.

 There is no `transcodeStreamURL`: that is a Stash server concept, and a local
 asset has no server to transcode it. AVFoundation decodes everything the camera
 produces, so the WebKit fallback is not needed either.
 */

import AVFoundation
import Foundation
import Photos

final class PhotosVideoSource: VideoSource, @unchecked Sendable {

    private let pager = PhotosAssetPager(mediaType: .video)

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        let result = pager.page(page, pageSize: pageSize, criteria: filter?.photosCriteria ?? PhotosFilterCriteria())

        var videos: [GalleryVideo] = []
        videos.reserveCapacity(result.assets.count)
        for asset in result.assets {
            guard let url = PhotosAssetURL.url(forLocalIdentifier: asset.localIdentifier) else { continue }
            videos.append(
                GalleryVideo(
                    identity: url.absoluteString,
                    // No stashId: there is no scene on any server behind this,
                    // so rating, o-counter and destroy correctly stay unavailable.
                    thumbnailURL: url,
                    streamURL: url,
                    title: asset.originalFilename,
                    duration: asset.duration,
                    sourceWidth: asset.pixelWidth,
                    sourceHeight: asset.pixelHeight,
                    fileName: asset.originalFilename
                )
            )
        }

        return VideoFetchResult(videos: videos, hasMore: result.hasMore, totalCount: result.total)
    }
}
