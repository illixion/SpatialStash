/*
 Hypnos - Image Source Protocol

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
    case mediaAuthenticationFailed

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
        case .mediaAuthenticationFailed:
            return "Server accepted the key for browsing, but a real image failed to load. Stash checks the key's signature separately for images/videos — a stale key can fail that even though metadata keeps working. Try regenerating the API key in Stash (Settings → Security) and entering the new one here."
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

// MARK: - Cancellation

extension Error {
    /// Whether this error is a cancellation rather than a failure.
    ///
    /// The distinction matters wherever an error decides what to do with content
    /// already on screen: a *failed* load means what is showing no longer matches
    /// what was asked for, while a *cancelled* one means nobody is waiting for an
    /// answer any more and the old contents are still the best available.
    ///
    /// `URLSession.data(for:)` surfaces task cancellation as `URLError.cancelled`
    /// rather than `CancellationError`, so both spellings have to be caught, and
    /// `NSError`'s `underlyingErrors` is checked because wrappers are common.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        return nsError.underlyingErrors.contains { $0.isCancellation }
    }
}
