/*
 Spatial Stash - Async Image Loader

 Actor-based image loader with caching to prevent duplicate requests.
 Supports both static images and animated GIFs.
 */

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

    /// Load an image from a URL, using cache if available
    /// - Parameter url: The URL to load the image from
    /// - Returns: The loaded image, or nil if loading failed
    func loadImage(from url: URL) async throws -> UIImage? {
        // Check cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.image
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.image
        }

        // Start new load task
        let task = Task<CachedImageData?, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = UIImage(data: data) else {
                return nil
            }

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache the image with data
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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
        // Check cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.data
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value?.data
        }

        // Start new load task
        let task = Task<CachedImageData?, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = UIImage(data: data) else {
                return nil
            }

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache the image with data
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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
        // Check cache first
        if let cached = cache.object(forKey: url as NSURL) {
            return (cached.image, cached.data)
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            if let result = try await existingTask.value {
                return (result.image, result.data)
            }
            return nil
        }

        // Start new load task
        let task = Task<CachedImageData?, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = UIImage(data: data) else {
                return nil
            }

            // Create cached data wrapper
            let cachedData = CachedImageData(image: image, data: data)

            // Cache the image with data
            let cost = data.count
            cache.setObject(cachedData, forKey: url as NSURL, cost: cost)

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

    /// Clear the image cache
    func clearCache() {
        cache.removeAllObjects()
    }

    /// Remove a specific image from cache
    func removeFromCache(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
