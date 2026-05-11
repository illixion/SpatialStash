/*
 Spatial Stash - Remote Content Provider

 SlideshowContentProvider implementation that consumes posts pushed by
 the RoboFrame server's `playback` channel. The server is the single
 DuckDB reader and broadcasts `playback { current, next }` frames over
 the WebSocket. RemoteViewerModel feeds those posts into the buffer below
 via `enqueueFromPlayback`, and the engine's prefetch loop pulls them out
 through `fetchMoreContent`.
 */

import CoreGraphics
import os
import UIKit

@MainActor
class RemoteContentProvider: SlideshowContentProvider {
    let apiClient: RemoteAPIClient
    let baseURL: String
    let accessToken: String

    /// Posts the server has nominated via `playback`. Drained by the
    /// engine's prefetch loop on each `fetchMoreContent` call.
    private var pending: [RemotePost] = []

    /// IDs already enqueued via `playback`. Used to suppress duplicate
    /// frames the server sometimes emits at session start — without this
    /// the engine would prefetch and visibly display the same pair twice
    /// (A → B → A → B …) before catching up to the next push. Cleared on
    /// `resetPagination` so a tag-list / remote jump can resurface the
    /// same ids legitimately.
    private var seenIds: Set<Int> = []

    init(apiClient: RemoteAPIClient, baseURL: String, accessToken: String) {
        self.apiClient = apiClient
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    /// Called by RemoteViewerModel when a `playback` frame arrives. The posts
    /// here are the server's `current` / `next` reconstructed from the playback
    /// payload (just id + ext; other fields are nil — the engine only uses
    /// `_id`, `file_ext`, and `tags` for routing).
    func enqueueFromPlayback(_ posts: [RemotePost]) {
        for post in posts where !seenIds.contains(post._id) {
            pending.append(post)
            seenIds.insert(post._id)
        }
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        if !pending.isEmpty {
            let drained = pending
            pending.removeAll()
            return drained.filter { post in
                !blockedPosts.contains(post._id) &&
                !post.tags.contains(where: { blockedTags.contains($0) })
            }
        }
        // Yield a beat so the engine's prefetch loop doesn't tight-spin
        // between server pushes when the channel is paused or briefly
        // empty between ticks.
        try? await Task.sleep(for: .milliseconds(500))
        return []
    }

    func downloadImage(for post: RemotePost, maxResolution: Int) async -> (image: UIImage, data: Data)? {
        guard let imageURL = resolveImageURL(for: post) else { return nil }

        let maxRes = maxResolution
        return await Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                if maxRes > 0 {
                    let maxDim = CGFloat(maxRes)
                    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                    if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) {
                        let downsampleOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxDim,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) {
                            return (UIImage(cgImage: cgImage), data)
                        }
                    }
                }
                if let image = UIImage(data: data) {
                    return (image, data)
                }
                return nil
            } catch {
                AppLogger.remoteViewer.error("Failed to load post \(post._id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    func resolveImageURL(for post: RemotePost) -> URL? {
        apiClient.getImageURL(baseURL: baseURL, postId: post._id, accessToken: accessToken)
    }

    func onPostDisplayed(_ post: RemotePost) async {
        try? await apiClient.addToHistory(baseURL: baseURL, postId: post._id, accessToken: accessToken)
    }

    func resetPagination() {
        // The orchestrator manages pagination; locally we just drop any
        // server-pushed posts that haven't been consumed yet, and forget
        // which ids we've seen so a legitimate replay (e.g. tag-list
        // change) can resurface the same post.
        pending.removeAll()
        seenIds.removeAll()
    }
}
