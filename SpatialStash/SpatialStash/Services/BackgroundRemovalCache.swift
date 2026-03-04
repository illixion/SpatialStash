/*
 Spatial Stash - Background Removal Cache

 Persistent cache for background-removed images using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Separate from DiskImageCache to allow independent cache management.
 */

import Foundation
import os
import UIKit

actor BackgroundRemovalCache {
    static let shared = BackgroundRemovalCache()

    private let cacheDirectory: URL
    private let maxCacheSize: Int64 // Maximum cache size in bytes
    private let fileManager = FileManager.default

    private init() {
        // Use the Caches directory - Apple-approved for temporary cache storage
        // Store in separate subdirectory from main image cache
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("BackgroundRemovalCache", isDirectory: true)

        // Default max size: 2000 MB
        maxCacheSize = 2000 * 1024 * 1024

        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Mark directory as excluded from backups (Apple requirement for caches)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)
    }

    /// Generate a cache key from a URL with background removal suffix
    private func cacheKey(for url: URL) -> String {
        // Use SHA256 hash of URL string + "backgroundRemoved" suffix as filename
        let urlString = url.absoluteString + ":backgroundRemoved"
        let data = Data(urlString.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Get the file URL for a cached background-removed image
    private func cacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key)
    }

    /// Return cached file URL if present
    func cachedFileURL(for url: URL) -> URL? {
        let fileURL = cacheFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Check if a background-removed image is cached
    func isCached(url: URL) -> Bool {
        let fileURL = cacheFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Load background-removed image data from disk cache
    func loadData(for url: URL) -> Data? {
        let fileURL = cacheFileURL(for: url)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Update access time for LRU tracking
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )

        return try? Data(contentsOf: fileURL)
    }

    /// Save background-removed image data to disk cache
    func saveData(_ data: Data, for url: URL) {
        let fileURL = cacheFileURL(for: url)

        do {
            try data.write(to: fileURL)

            // Check cache size and cleanup if needed
            Task { [self] in
                await self.cleanupIfNeeded()
            }
        } catch {
            AppLogger.diskCache.error("Failed to save background-removed image: \(error.localizedDescription, privacy: .public)")
        }
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

        AppLogger.diskCache.notice("Background removal cache size (\(currentSize / 1024 / 1024, privacy: .public) MB) exceeds limit, cleaning up...")

        // Get all cached files with their modification dates
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
                AppLogger.diskCache.warning("Failed to remove background-removed image cache file: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLogger.diskCache.info("Background removal cache freed \(freedSize / 1024 / 1024, privacy: .public) MB")
    }

    /// Clear entire background removal cache
    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        AppLogger.diskCache.notice("Background removal cache cleared")
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

// CommonCrypto for SHA256 hashing
import CommonCrypto
