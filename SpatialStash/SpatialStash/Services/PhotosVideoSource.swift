/*
 Spatial Stash - Photos Video Source

 `VideoSource` over the device photo library, optionally scoped to one album.

 Mirrors `PhotosImageSource`, including the per-instance fetch snapshot and the
 reason for it. What differs is what the URL has to survive: an image is decoded
 to bytes, but a video is handed to AVPlayer, which needs something it can open.

 So `streamURL` carries the synthetic `photos-asset:///` URL as identity, and
 `VideoWindowModel` resolves it to a playable URL once per video before the
 renderer is probed. The playable URL is never stored on the model, because it
 is valid for one launch only — the identity is what persists, and it is what
 the depth cache and 3D settings key on.

 There is no `transcodeStreamURL`: that is a Stash server concept, and a local
 asset has no server to transcode it. AVFoundation decodes everything the
 camera produces, so the WebKit fallback is not needed either.
 */

import AVFoundation
import Foundation
import Photos

final class PhotosVideoSource: VideoSource, @unchecked Sendable {

    private let collection: PHAssetCollection?
    private let lock = NSLock()
    private var cachedFetch: PHFetchResult<PHAsset>?

    init(collection: PHAssetCollection? = nil) {
        self.collection = collection
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        // Stash-shaped filters have no analogue here, so they are ignored
        // rather than half-applied.
        guard PhotosAuthorization.isReadable else {
            return VideoFetchResult(videos: [], hasMore: false, totalCount: 0)
        }

        let assets = fetchResult()
        let total = assets.count
        let start = page * pageSize
        guard start < total else {
            return VideoFetchResult(videos: [], hasMore: false, totalCount: total)
        }
        let end = min(start + pageSize, total)

        var videos: [GalleryVideo] = []
        videos.reserveCapacity(end - start)
        for index in start..<end {
            let asset = assets.object(at: index)
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

        return VideoFetchResult(videos: videos, hasMore: end < total, totalCount: total)
    }

    // MARK: - Fetch

    private func fetchResult() -> PHFetchResult<PHAsset> {
        lock.lock()
        defer { lock.unlock() }
        if let cachedFetch { return cachedFetch }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

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
