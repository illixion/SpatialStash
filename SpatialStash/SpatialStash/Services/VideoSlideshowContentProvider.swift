/*
 Spatial Stash - Video Slideshow Content Provider

 SlideshowContentProvider implementation that fetches videos from a
 VideoSource (GraphQL scenes, local files, etc.) and presents them as
 video posts for the slideshow engine. Mirrors GalleryContentProvider,
 but maps GalleryVideo → RemotePost with a video file extension so the
 engine routes each post through its video display path.
 */

import Foundation
import UIKit
import os

@MainActor
class VideoSlideshowContentProvider: SlideshowContentProvider {
    let videoSource: any VideoSource
    var filter: SceneFilterCriteria?

    private var page: Int = 0
    /// URL mapping for video posts (RemotePost._id → streamURL)
    private var videoURLMap: [Int: URL] = [:]

    init(videoSource: any VideoSource, filter: SceneFilterCriteria? = nil) {
        self.videoSource = videoSource
        self.filter = filter
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        do {
            let result = try await videoSource.fetchVideos(page: page, pageSize: 20, filter: filter)
            page += 1

            let posts = result.videos.map { video -> RemotePost in
                // Stash stream URLs often have no path extension; fall back
                // to "mp4" so SlideshowEngine.videoExtensions matches and the
                // engine routes the post through its video display path.
                let pathExt = video.streamURL.pathExtension.lowercased()
                let ext = pathExt.isEmpty ? "mp4" : pathExt
                return RemotePost(
                    _id: abs(video.stashId.hashValue),
                    file_ext: ext,
                    tags: [],
                    rating: nil, image_width: video.sourceWidth, image_height: video.sourceHeight,
                    fav_count: nil, md5: nil, parent_id: nil,
                    score: nil, ratio: nil, path: video.streamURL.absoluteString,
                    // nil duration keeps effectiveDelay on the strict configured
                    // interval — videos autoplay and cut off like animated GIFs.
                    duration: nil
                )
            }
            for (video, post) in zip(result.videos, posts) {
                videoURLMap[post._id] = video.streamURL
            }
            AppLogger.remoteViewer.info("Video slideshow: fetched \(posts.count, privacy: .public) videos")
            return posts
        } catch {
            AppLogger.remoteViewer.error("Video slideshow fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func downloadImage(for post: RemotePost, maxResolution: Int) async -> (image: UIImage, data: Data)? {
        // Never reached for video posts — the engine routes by extension to
        // displayVideo before calling this.
        nil
    }

    func resolveImageURL(for post: RemotePost) -> URL? {
        videoURLMap[post._id]
    }

    func onPostDisplayed(_ post: RemotePost) async {
        // No server-side history for video slideshow mode
    }

    func resetPagination() {
        page = 0
        videoURLMap.removeAll()
    }
}
