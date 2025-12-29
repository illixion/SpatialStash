/*
 Spatial Stash - Async Image Loader

 Actor-based image loader with caching to prevent duplicate requests.
 */

import SwiftUI

actor ImageLoader {
    static let shared = ImageLoader()

    private var cache = NSCache<NSURL, UIImage>()
    private var inProgressTasks: [URL: Task<UIImage?, Error>] = [:]

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
            return cached
        }

        // Check if already loading
        if let existingTask = inProgressTasks[url] {
            return try await existingTask.value
        }

        // Start new load task
        let task = Task<UIImage?, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Validate response
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = UIImage(data: data) else {
                return nil
            }

            // Cache the image
            let cost = data.count
            cache.setObject(image, forKey: url as NSURL, cost: cost)

            return image
        }

        inProgressTasks[url] = task

        defer {
            inProgressTasks[url] = nil
        }

        return try await task.value
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
