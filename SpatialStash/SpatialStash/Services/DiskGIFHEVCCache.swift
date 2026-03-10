/*
 Spatial Stash - Disk GIF HEVC Cache

 Persistent cache for GIF-to-HEVC converted videos using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Separate from other caches to allow independent cache management.
 */

import CommonCrypto
import Foundation
import os

actor DiskGIFHEVCCache {
    static let shared = DiskGIFHEVCCache()

    private let cacheDirectory: URL
    private let maxCacheSize: Int64
    private let fileManager = FileManager.default

    private init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("GIFHEVCCache", isDirectory: true)

        // 1 GB max
        maxCacheSize = 1000 * 1024 * 1024

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)
    }

    // MARK: - Cache Key

    private func cacheKey(for url: URL) -> String {
        let urlString = url.absoluteString
        let data = Data(urlString.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key + ".mp4")
    }

    // MARK: - Public API

    /// Return cached file URL if present
    func cachedFileURL(for url: URL) -> URL? {
        let fileURL = cacheFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Move a converted .mp4 from a temporary location into the cache
    func saveFile(from tempURL: URL, for sourceURL: URL) {
        let destinationURL = cacheFileURL(for: sourceURL)

        do {
            // Remove existing file if present (e.g. partial/corrupt)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)

            Task { [self] in
                self.cleanupIfNeeded()
            }
        } catch {
            AppLogger.gifConverter.error("Failed to save GIF HEVC to cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clear entire cache
    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        AppLogger.gifConverter.notice("GIF HEVC cache cleared")
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

    // MARK: - LRU Eviction

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

    private func cleanupIfNeeded() {
        let currentSize = getCacheSize()
        guard currentSize > maxCacheSize else { return }

        AppLogger.gifConverter.notice("GIF HEVC cache size (\(currentSize / 1024 / 1024, privacy: .public) MB) exceeds limit, cleaning up...")

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

        files.sort { $0.date < $1.date }

        let targetSize = Int64(Double(maxCacheSize) * 0.8)
        var freedSize: Int64 = 0
        let sizeToFree = currentSize - targetSize

        for file in files {
            guard freedSize < sizeToFree else { break }
            do {
                try fileManager.removeItem(at: file.url)
                freedSize += file.size
            } catch {
                AppLogger.gifConverter.warning("Failed to remove GIF HEVC cache file: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLogger.gifConverter.info("GIF HEVC cache freed \(freedSize / 1024 / 1024, privacy: .public) MB")
    }
}
