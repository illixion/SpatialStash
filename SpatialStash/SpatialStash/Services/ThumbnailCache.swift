/*
 Spatial Stash - Thumbnail Cache

 Dedicated cache for generated thumbnails with disk persistence.
 Uses file modification time to invalidate stale thumbnails.
 Optimized for small images to minimize memory usage.
 */

import CommonCrypto
import Foundation
import os
import UIKit

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cacheDirectory: URL
    private let maxCacheSize: Int64 // Maximum cache size in bytes
    private let fileManager = FileManager.default

    /// Memory cache for recently accessed thumbnails (much smaller than full image cache)
    private var memoryCache = NSCache<NSString, UIImage>()

    private init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("ThumbnailCache", isDirectory: true)

        // Thumbnails are small, 100 MB is plenty
        maxCacheSize = 100 * 1024 * 1024

        // Configure memory cache for thumbnails (small images, more count)
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB for memory

        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Mark directory as excluded from backups
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)
    }

    /// Generate a cache key that includes file modification time
    /// This invalidates cached thumbnails when the source file changes
    private func cacheKey(for url: URL) -> String {
        var keyString = url.absoluteString

        // Include modification time for local files to detect changes
        if url.isFileURL,
           let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            keyString += "_\(Int(modDate.timeIntervalSince1970))"
        }

        let data = Data(keyString.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Get the file URL for a cached thumbnail
    private func cacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key + ".jpg")
    }

    /// Load a cached thumbnail
    /// - Parameter url: The source image URL
    /// - Returns: The cached thumbnail UIImage, or nil if not cached
    func loadThumbnail(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Check memory cache first
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        // Update access time for LRU
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )

        // Restore to memory cache
        let cost = data.count
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        return image
    }

    /// Save a thumbnail to cache
    /// - Parameters:
    ///   - image: The thumbnail image to cache
    ///   - url: The source image URL (used as key)
    func saveThumbnail(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)

        // Save to memory cache
        // Estimate cost as width * height * 4 bytes per pixel
        let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        // Save to disk as JPEG (smaller than PNG for photos)
        let fileURL = cacheFileURL(for: url)
        if let data = image.jpegData(compressionQuality: 0.8) {
            do {
                try data.write(to: fileURL)

                // Check cache size and cleanup if needed
                Task {
                    await self.cleanupIfNeeded()
                }
            } catch {
                AppLogger.diskCache.error("Failed to save thumbnail: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Check if a thumbnail is cached (memory or disk)
    func isCached(for url: URL) -> Bool {
        let key = cacheKey(for: url)

        // Check memory first
        if memoryCache.object(forKey: key as NSString) != nil {
            return true
        }

        // Check disk
        let fileURL = cacheFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Get total cache size in bytes
    private func getCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    /// Cleanup cache if it exceeds max size (LRU eviction)
    private func cleanupIfNeeded() {
        let currentSize = getCacheSize()

        guard currentSize > maxCacheSize else { return }

        AppLogger.diskCache.notice("Thumbnail cache size (\(currentSize / 1024 / 1024, privacy: .public) MB) exceeds limit, cleaning up...")

        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var files: [(url: URL, size: Int64, date: Date)] = []

        while let fileURL = enumerator.nextObject() as? URL {
            if let resourceValues = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ),
               let fileSize = resourceValues.fileSize,
               let modDate = resourceValues.contentModificationDate {
                files.append((fileURL, Int64(fileSize), modDate))
            }
        }

        // Sort by modification date (oldest first for LRU eviction)
        files.sort { $0.date < $1.date }

        // Remove oldest files until we're under 80% of max size
        let targetSize = Int64(Double(maxCacheSize) * 0.8)
        var freedSize: Int64 = 0
        let sizeToFree = currentSize - targetSize

        for file in files {
            guard freedSize < sizeToFree else { break }

            do {
                try fileManager.removeItem(at: file.url)
                freedSize += file.size
            } catch {
                AppLogger.diskCache.warning("Failed to remove thumbnail: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLogger.diskCache.info("Freed \(freedSize / 1024 / 1024, privacy: .public) MB from thumbnail cache")
    }

    /// Clear entire thumbnail cache
    func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        AppLogger.diskCache.notice("Thumbnail cache cleared")
    }

    /// Get cache statistics
    func getCacheStats() -> (fileCount: Int, totalSize: Int64) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return (0, 0)
        }

        var totalSize: Int64 = 0
        for fileURL in contents {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return (contents.count, totalSize)
    }
}
