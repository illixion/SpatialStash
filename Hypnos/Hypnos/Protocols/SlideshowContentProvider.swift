/*
 Hypnos - Slideshow Content Provider Protocol

 Abstracts content fetching for the slideshow engine. Implementations
 provide posts from different sources (remote API, local gallery, etc.)
 while the engine handles timing, transitions, and prefetching.
 */

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// Result of a slideshow download. A still is decoded to a `UIImage` for the
/// texture/crossfade/3D pipeline; a `.video` is a post the server handed back
/// as H.264 (an animated post, or a video) to be rendered via the
/// video-in-`<img>` path instead of decoded as a still.
enum DownloadedMedia {
    case still(image: UIImage, data: Data)
    case video(url: URL)
}

@MainActor
protocol SlideshowContentProvider: AnyObject {
    /// Fetch a batch of posts for the slideshow queue.
    /// The provider manages its own pagination/cursor state internally.
    /// - Parameters:
    ///   - tagQuery: Space-separated tag query string
    ///   - ratioRange: Optional aspect ratio range filter (e.g. "1.32..1.79")
    ///   - blockedPosts: Post IDs to exclude
    ///   - blockedTags: Tags to exclude (posts containing any are filtered)
    /// - Returns: Array of posts to add to the queue
    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost]

    /// Download an image for display, or detect that the server returned a
    /// video (H.264) to be rendered via the video-in-`<img>` path.
    /// - Parameters:
    ///   - post: The post to download the image for
    ///   - maxResolution: Maximum dimension for downsampling (0 = no limit)
    /// - Returns: `.still`/`.video`, or nil on failure
    func downloadImage(for post: RemotePost, maxResolution: Int) async -> DownloadedMedia?

    /// Resolve the display URL for a post.
    func resolveImageURL(for post: RemotePost) -> URL?

    /// Streaming (HLS) URL for a video post — the fallback used after native
    /// playback of the raw source fails. `nil` (default) means no streaming
    /// fallback is available (e.g. local files).
    func hlsURL(for post: RemotePost) -> URL?

    /// Called when a post is displayed. Use for server-side history tracking, etc.
    func onPostDisplayed(_ post: RemotePost) async

    /// Reset pagination state. Called when tag list changes or a fresh start is needed.
    func resetPagination()

    /// When true, video posts (and animated posts the server delivers as H.264)
    /// are rendered through the video-in-`<img>` path — a muted, looping
    /// animated image whose playback the web view manages automatically (pause
    /// / resume on room transitions) — instead of an AVPlayer. Only the
    /// RoboFrame remote slideshow opts in; dedicated video playback keeps the
    /// real player.
    var rendersVideoAsAnimatedImage: Bool { get }
}

extension SlideshowContentProvider {
    var rendersVideoAsAnimatedImage: Bool { false }
    func hlsURL(for post: RemotePost) -> URL? { nil }
}
