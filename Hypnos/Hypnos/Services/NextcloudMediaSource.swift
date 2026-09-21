/*
 Hypnos - Nextcloud Media Sources

 Adapts the NextcloudMedia package's DAV SEARCH client to the app's
 `ImageSource` / `VideoSource` contracts.

 Nextcloud has no media API in core — no tags, no albums, no ratings — so
 these are deliberately thin: a page of files under the configured root,
 newest first, and nothing else. The filter arguments are ignored (the
 protocols' default implementations already do that, but these are explicit
 about it because the Filters tab is hidden for this library and a silently
 dropped filter would otherwise be indistinguishable from a broken one).

 Auth is not visible here. Every URL these produce needs a Basic
 `Authorization` header, which `MediaAuthorization` attaches by host when the
 loaders and players issue the request — see `AppModel.updateNextcloudClient`
 for the registration.
 */

import Foundation
import NextcloudMedia

// MARK: - Mapping

enum NextcloudItemAdapter {

    /// Preview size to request. Nextcloud renders previews on demand and
    /// caches them, so this is a real cost on the server the first time each
    /// image is seen; 1024 is large enough for a grid cell on a Retina
    /// display without asking it to render something near full size.
    static let previewPixelSize = 1024

    /// A stable per-item key.
    ///
    /// Keyed on the Nextcloud file id rather than the path, so moving or
    /// renaming a file on the server doesn't orphan everything the app has
    /// remembered about it — the depth cache above all, which is expensive to
    /// rebuild. The `nextcloud:` prefix keeps it from ever being mistaken for
    /// a Stash id, which is a bare decimal string (`MediaIdentity.isStashID`)
    /// exactly as a Nextcloud file id is.
    static func identity(for item: NextcloudItem) -> String {
        "nextcloud:\(item.fileID)"
    }

    static func image(from item: NextcloudItem, server: NextcloudServer) -> GalleryImage? {
        // No preview means the server can't render this format; the grid cell
        // would be permanently blank. The original is still downloadable, so
        // fall back to it rather than dropping the image from the library.
        let thumbnail = server.previewURL(fileID: item.fileID, size: previewPixelSize)
            ?? item.downloadURL

        return GalleryImage(
            // Deliberately nil: this field is a *Stash* id, and every GraphQL
            // call site keys off its presence to decide whether the item can
            // be rated, mutated or destroyed on a server. A Nextcloud file id
            // is also a bare decimal string, so putting one here would make
            // those call sites fire at Stash with an id that isn't theirs.
            stashId: nil,
            thumbnailURL: thumbnail,
            fullSizeURL: item.downloadURL,
            title: item.filename,
            source: .nextcloud,
            fileName: item.filename,
            sourceWidth: item.pixelSize?.width,
            sourceHeight: item.pixelSize?.height
        )
    }

    static func video(from item: NextcloudItem, server: NextcloudServer) -> GalleryVideo? {
        let thumbnail = server.previewURL(fileID: item.fileID, size: previewPixelSize)
            ?? item.downloadURL

        return GalleryVideo(
            identity: identity(for: item),
            stashId: nil,
            thumbnailURL: thumbnail,
            streamURL: item.downloadURL,
            // Nextcloud serves the stored file and nothing else — there is no
            // server-side transcode to fall back to. A format AVFoundation
            // can't decode therefore has nowhere to escalate to, which is why
            // `hasNativePlayableTranscode` (and so the fake-3D route for such
            // a file) is correctly false here.
            transcodeStreamURL: nil,
            previewURL: nil,
            title: item.filename,
            sourceWidth: item.pixelSize?.width,
            sourceHeight: item.pixelSize?.height,
            fileName: item.filename
        )
    }
}

// MARK: - Images

struct NextcloudImageSource: ImageSource {
    private let client: NextcloudClient

    init(client: NextcloudClient) {
        self.client = client
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        let server = await client.currentServer
        let query = NextcloudQuery(
            kind: .images,
            sortField: .lastModified,
            descending: true,
            offset: page * pageSize,
            limit: pageSize
        )
        let result = try await client.search(query)
        let images = result.items.compactMap { NextcloudItemAdapter.image(from: $0, server: server) }

        // No total: the SEARCH response carries only the page it returned, and
        // asking for a count would mean a second full-library query per page.
        // `hasMore` from the page is what the grid's paging actually reads.
        return ImageFetchResult(images: images, hasMore: result.hasMore, totalCount: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        // Nextcloud has nothing to filter by — see the file header.
        try await fetchImages(page: page, pageSize: pageSize)
    }
}

// MARK: - Videos

struct NextcloudVideoSource: VideoSource {
    private let client: NextcloudClient

    init(client: NextcloudClient) {
        self.client = client
    }

    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        let server = await client.currentServer
        let query = NextcloudQuery(
            kind: .videos,
            sortField: .lastModified,
            descending: true,
            offset: page * pageSize,
            limit: pageSize
        )
        let result = try await client.search(query)
        let videos = result.items.compactMap { NextcloudItemAdapter.video(from: $0, server: server) }
        return VideoFetchResult(videos: videos, hasMore: result.hasMore, totalCount: nil)
    }

    func fetchVideos(page: Int, pageSize: Int, filter: SceneFilterCriteria?) async throws -> VideoFetchResult {
        try await fetchVideos(page: page, pageSize: pageSize)
    }
}
