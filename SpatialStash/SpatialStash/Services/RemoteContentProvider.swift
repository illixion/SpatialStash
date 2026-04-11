/*
 Spatial Stash - Remote Content Provider

 SlideshowContentProvider implementation that fetches content from
 the RoboFrame API via RemoteAPIClient.
 */

import CoreGraphics
import os
import UIKit

@MainActor
class RemoteContentProvider: SlideshowContentProvider {
    let apiClient: RemoteAPIClient
    let baseURL: String

    /// Pagination cursor managed internally. Randomized on init and on wraparound.
    var cursor: String? = String(Double.random(in: 0..<1))

    init(apiClient: RemoteAPIClient, baseURL: String) {
        self.apiClient = apiClient
        self.baseURL = baseURL
    }

    func fetchMoreContent(
        tagQuery: String,
        ratioRange: String?,
        blockedPosts: Set<Int>,
        blockedTags: Set<String>
    ) async -> [RemotePost] {
        // Run the network request in a detached task so it isn't cancelled
        // when the slideshow task is replaced (e.g. by goToNextImage or scene phase changes)
        let apiClient = self.apiClient
        let baseURL = self.baseURL
        let cursor = self.cursor
        let result: RemoteSearchResponse? = await Task.detached {
            do {
                return try await apiClient.search(
                    baseURL: baseURL,
                    tags: tagQuery,
                    ratioRange: ratioRange,
                    cursor: cursor
                )
            } catch {
                AppLogger.remoteViewer.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value

        guard let response = result else { return [] }

        // Filter blocked posts client-side
        let filtered = response.results.filter { post in
            !blockedPosts.contains(post._id) &&
            !post.tags.contains(where: { blockedTags.contains($0) })
        }

        // Update cursor from server response. If server returns 0,
        // it means we've wrapped around — re-randomize to avoid
        // fetching the same set repeatedly.
        if let next = response.nextCursor {
            let cursorStr = next.stringValue
            if cursorStr == "0" {
                self.cursor = String(Double.random(in: 0..<1))
            } else {
                self.cursor = cursorStr
            }
        }

        AppLogger.remoteViewer.info("Fetched \(response.results.count, privacy: .public) posts, \(filtered.count, privacy: .public) after filtering")
        return filtered
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
        apiClient.getImageURL(baseURL: baseURL, postId: post._id)
    }

    func onPostDisplayed(_ post: RemotePost) async {
        try? await apiClient.addToHistory(baseURL: baseURL, postId: post._id)
    }

    func resetPagination() {
        cursor = String(Double.random(in: 0..<1))
    }
}
