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
        // Configure cache limits
        cache.countLimit = 100 // Maximum number of cached images
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
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
            cache.setObject(cachedData, forKey: url as NSURL, cost: diskData.count)
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
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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
            cache.setObject(cachedData, forKey: url as NSURL, cost: diskData.count)
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
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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
            cache.setObject(cachedData, forKey: url as NSURL, cost: diskData.count)
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
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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
        cache.setObject(cachedData, forKey: url as NSURL, cost: data.count)

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
}
