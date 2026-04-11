/*
 Spatial Stash - Slideshow Content Provider Protocol

 Abstracts content fetching for the slideshow engine. Implementations
 provide posts from different sources (remote API, local gallery, etc.)
 while the engine handles timing, transitions, and prefetching.
 */

import UIKit

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

    /// Download and optionally downsample an image for display.
    /// - Parameters:
    ///   - post: The post to download the image for
    ///   - maxResolution: Maximum dimension for downsampling (0 = no limit)
    /// - Returns: Tuple of image and raw data, or nil on failure
    func downloadImage(for post: RemotePost, maxResolution: Int) async -> (image: UIImage, data: Data)?

    /// Resolve the display URL for a post.
    func resolveImageURL(for post: RemotePost) -> URL?

    /// Called when a post is displayed. Use for server-side history tracking, etc.
    func onPostDisplayed(_ post: RemotePost) async

    /// Reset pagination state. Called when tag list changes or a fresh start is needed.
    func resetPagination()
}
