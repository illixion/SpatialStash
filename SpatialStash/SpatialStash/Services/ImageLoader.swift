/*
 Spatial Stash - Async Image Loader

 Actor-based image loader with caching to prevent duplicate requests.
 Supports both static images and animated GIFs.
 */

import os
import SwiftUI

/// Wrapper class to store image data in NSCache
final class CachedImageData: NSObject, @unchecked Sendable {
    let image: UIImage
    let data: Data

    init(image: UIImage, data: Data) {
        self.image = image
        self.data = data
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private var cache = NSCache<NSURL, CachedImageData>()
    private var inProgressTasks: [URL: Task<CachedImageData?, Error>] = [:]

    private init() {
        // Configure cache limits (costs reflect true decoded image sizes)
        cache.countLimit = 20
        cache.totalCostLimit = 512 * 1024 * 1024 // 512 MB
    }

    /// Estimate the actual in-memory cost of a cached image (decoded pixels + compressed data)
    private nonisolated func estimatedMemoryCost(image: UIImage, data: Data) -> Int {
        let pixelCost: Int
        if let cgImage = image.cgImage {
            pixelCost = cgImage.width * cgImage.height * 4
        } else {
            pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return pixelCost + data.count
    }

    /// Normalize an image by redrawing it to avoid Core Graphics decoding issues
    /// with certain 24-bit image formats (rdar://143602439)
    private nonisolated func normalizeImage(_ image: UIImage) -> UIImage {
        // Skip normalization for animated images or images without cgImage
        guard let cgImage = image.cgImage else {
            return image
        }

        // Redraw the image in a new graphics context with a compatible pixel format
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: cgImage.width, height: cgImage.height),
            format: format
        )

        return renderer.image { context in
            // Draw the original image into the new context
            UIImage(cgImage: cgImage, scale: 1.0, orientation: image.imageOrientation)
                .draw(in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
    }

    /// Load an image from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: The loaded image, or nil if loading failed
    func loadImage(from url: URL) async throws -> UIImage? {
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.image
        }

        // Handle local file URLs directly
        if url.isFileURL {
            let result = try await loadLocalImageWithData(from: url)
            return result?.image
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return image
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.image
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        return try await task.value?.image
    }

    /// Load image data from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: The raw image data, or nil if loading failed
    func loadImageData(from url: URL) async throws -> Data? {
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.data
        }

        // Handle local file URLs directly
        if url.isFileURL {
            let result = try await loadLocalImageWithData(from: url)
            return result?.data
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return diskData
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.data
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        return try await task.value?.data
    }

    /// Load ONLY the raw Data for a URL without decoding to UIImage.
    /// Avoids the expensive normalizeImage() allocation for cases where
    /// only the bytes are needed (e.g. GIF detection).
    func loadRawData(from url: URL) async throws -> Data? {
        // Check memory cache first (if already loaded, return cached data)
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.data
        }

        // Handle local file URLs directly
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url) {
            return diskData
        }

        // Download without decoding to UIImage
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        // Cache to disk only (skip memory cache since we're not decoding)
        await DiskImageCache.shared.saveData(data, for: url)

        return data
    }

    /// Load both image and data from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: A tuple of (UIImage, Data), or nil if loading failed
    func loadImageWithData(from url: URL) async throws -> (image: UIImage, data: Data)? {
        // Check memory cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return (cached.image, cached.data)
        }

        // Handle local file URLs directly
        if url.isFileURL {
            return try await loadLocalImageWithData(from: url)
        }

        // Check disk cache for remote URLs
        if let diskData = await DiskImageCache.shared.loadData(for: url),
           let rawImage = UIImage(data: diskData) {
            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)
            // Restore to memory cache
            let cachedData = CachedImageData(image: image, data: diskData)
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: diskData))
            return (image, diskData)
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            if let result = try await existingTask.value {
                return (result.image, result.data)
            }
            return nil
        }

        // Start new load task for remote URLs
        let task = Task<CachedImageData?, Error> { [self] in
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let rawImage = UIImage(data: data) else {
                return nil
            }

            // Normalize the image to avoid Core Graphics decoding issues
            let image = normalizeImage(rawImage)

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache in memory
            cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

            // Cache to disk
            await DiskImageCache.shared.saveData(data, for: url)

            return cachedData
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        if let result = try await task.value {
            return (result.image, result.data)
        }
        return nil
    }

    /// Load image from a local file URL
    private func loadLocalImageWithData(from url: URL) async throws -> (image: UIImage, data: Data)? {
        // Read data from local file
        let data = try Data(contentsOf: url)

        guard let rawImage = UIImage(data: data) else {
            AppLogger.imageLoader.warning("Failed to create UIImage from local file: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Normalize the image to avoid Core Graphics decoding issues
        let image = normalizeImage(rawImage)

        // Cache in memory (but not to disk since it's already local)
        let cachedData = CachedImageData(image: image, data: data)
        cache.setObject(cachedData, forKey: url as NSURL, cost: estimatedMemoryCost(image: image, data: data))

        return (image, data)
    }

    /// Clear the image cache (both memory and disk)
    func clearCache() async {
        cache.removeAllObjects()
        await DiskImageCache.shared.clearCache()
    }

    /// Remove a specific image from cache
    func removeFromCache(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    // MARK: - Thumbnail Loading (Memory Efficient)

    /// Load a thumbnail for display in gallery views
    /// Uses memory-efficient downsampling for local files
    /// - Parameters:
    ///   - url: The image URL
    ///   - maxSize: Maximum thumbnail dimension (default 400px for 2x display)
    /// - Returns: A downsampled UIImage suitable for thumbnails
    func loadThumbnail(from url: URL, maxSize: CGFloat = ThumbnailGenerator.defaultThumbnailSize) async -> UIImage? {
        // For local files, use the efficient thumbnail system
        if url.isFileURL {
            return await loadLocalThumbnail(from: url, maxSize: maxSize)
        }

        // For remote URLs, use the regular loading (they're already thumbnails from server)
        return try? await loadImage(from: url)
    }

    /// Load a thumbnail with data (for animated GIF detection)
    /// - Parameters:
    ///   - url: The image URL
    ///   - maxSize: Maximum thumbnail dimension
    /// - Returns: Tuple of (thumbnail image, original data for GIF detection)
    func loadThumbnailWithData(from url: URL, maxSize: CGFloat = ThumbnailGenerator.defaultThumbnailSize) async -> (image: UIImage, data: Data, isAnimatedGIF: Bool)? {
        // For local files, use efficient thumbnail loading
        if url.isFileURL {
            // Check if it's an animated GIF first (without loading full image)
            let isAnimated = ThumbnailGenerator.shared.isAnimatedGIF(at: url)

            if isAnimated {
                // For animated GIFs, we need the full data for playback
                // But we can still be memory-efficient by not caching the full image
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                // Create a small preview image for non-animated display
                if let thumbnail = await loadLocalThumbnail(from: url, maxSize: maxSize) {
                    return (thumbnail, data, true)
                }
                return nil
            } else {
                // For static images, use efficient thumbnail
                if let thumbnail = await loadLocalThumbnail(from: url, maxSize: maxSize) {
                    // We don't need the original data for static thumbnails
                    // Return empty data since it won't be used
                    return (thumbnail, Data(), false)
                }
                return nil
            }
        }

        // For remote URLs, use existing loading
        if let result = try? await loadImageWithData(from: url) {
            let isAnimated = result.data.isAnimatedGIF
            return (result.image, result.data, isAnimated)
        }
        return nil
    }

    /// Load thumbnail for a local file using memory-efficient downsampling
    private func loadLocalThumbnail(from url: URL, maxSize: CGFloat) async -> UIImage? {
        // Check thumbnail cache first
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: url) {
            return cached
        }

        // Generate thumbnail using efficient downsampling
        guard let thumbnail = await ThumbnailGenerator.shared.generateThumbnail(for: url, maxSize: maxSize) else {
            AppLogger.imageLoader.warning("Failed to generate thumbnail for: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Cache the generated thumbnail
        await ThumbnailCache.shared.saveThumbnail(thumbnail, for: url)

        return thumbnail
    }
}
