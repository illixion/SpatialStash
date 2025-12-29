/*
 Spatial Stash - Image Source Protocol

 Protocol for fetching images from various sources (static URLs, GraphQL, etc.)
 */

import Foundation

/// Result of an image fetch operation
struct ImageFetchResult {
    let images: [GalleryImage]
    let hasMore: Bool
    let totalCount: Int?

    init(images: [GalleryImage], hasMore: Bool, totalCount: Int? = nil) {
        self.images = images
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

/// Error types for image source operations
enum ImageSourceError: Error, LocalizedError {
    case invalidURL(String)
    case networkError(underlying: Error)
    case noImagesAvailable
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let urlString):
            return "Invalid URL: \(urlString)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .noImagesAvailable:
            return "No images available from the source"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        }
    }
}

/// Protocol for image sources
/// Implement this protocol to provide images from different sources (static, GraphQL, etc.)
protocol ImageSource: Sendable {
    /// Fetch a page of images
    /// - Parameters:
    ///   - page: The page number (0-indexed)
    ///   - pageSize: Number of images per page
    /// - Returns: Result containing images and pagination info
    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult

    /// Fetch a page of images with filter criteria
    /// - Parameters:
    ///   - page: The page number (0-indexed)
    ///   - pageSize: Number of images per page
    ///   - filter: Optional filter criteria
    /// - Returns: Result containing images and pagination info
    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult
}

// Default implementation for sources that don't support filtering
extension ImageSource {
    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        // Default: ignore filter and fetch all
        return try await fetchImages(page: page, pageSize: pageSize)
    }
}
