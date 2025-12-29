/*
 Spatial Stash - Static URL Image Source

 PoC implementation using static HTTPS URLs.
 Replace with GraphQLImageSource for Stash app integration.
 */

import Foundation

/// Static image source with hardcoded HTTPS URLs for PoC
final class StaticURLImageSource: ImageSource, @unchecked Sendable {

    /// Sample remote URLs for testing
    /// Using picsum.photos which provides random high-quality images
    private let staticURLs: [URL]

    init() {
        // Generate a list of sample image URLs from picsum.photos
        // These are landscape images with good depth for 2D-to-3D conversion
        var urls: [URL] = []

        // Various picsum image IDs that work well for spatial photos
        let imageIds = [
            10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
            20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
            30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
            40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
            100, 101, 102, 103, 104, 106, 107, 108, 109, 110
        ]

        for id in imageIds {
            if let url = URL(string: "https://picsum.photos/id/\(id)/1920/1080") {
                urls.append(url)
            }
        }

        self.staticURLs = urls
    }

    /// Initialize with custom URLs
    init(urls: [URL]) {
        self.staticURLs = urls
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        // Simulate network delay for realistic behavior
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, staticURLs.count)

        guard startIndex < staticURLs.count else {
            return ImageFetchResult(
                images: [],
                hasMore: false,
                totalCount: staticURLs.count
            )
        }

        let pageURLs = Array(staticURLs[startIndex..<endIndex])
        let images = pageURLs.enumerated().map { index, url in
            GalleryImage(
                url: url,
                title: "Image \(startIndex + index + 1)"
            )
        }

        return ImageFetchResult(
            images: images,
            hasMore: endIndex < staticURLs.count,
            totalCount: staticURLs.count
        )
    }
}
