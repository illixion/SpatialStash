/*
 Spatial Stash - Disk GIF HEVC Cache

 Persistent cache for GIF-to-HEVC converted videos using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Separate from other caches to allow independent cache management.
 Size accounting and LRU eviction live in the shared LRUDiskCache engine.
 */

import Foundation
import os

actor DiskGIFHEVCCache {
    static let shared = DiskGIFHEVCCache()

    private let engine: LRUDiskCache
    private let fileManager = FileManager.default

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        engine = LRUDiskCache(
            directory: caches.appendingPathComponent("GIFHEVCCache", isDirectory: true),
            domain: .gifHEVC,
            log: AppLogger.gifConverter,
            formatVersion: 1
        )
    }

    // MARK: - Cache Key

    private func cacheFileURL(for url: URL) -> URL {
        engine.directory.appendingPathComponent(LRUDiskCache.sha256Key(url.absoluteString) + ".mp4")
    }

    // MARK: - Public API

    /// Return cached file URL if present
    func cachedFileURL(for url: URL) -> URL? {
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        // Update access time for LRU tracking
        engine.touch(fileURL)
        return fileURL
    }

    /// Move a converted .mp4 from a temporary location into the cache
    func saveFile(from tempURL: URL, for sourceURL: URL) {
        let destinationURL = cacheFileURL(for: sourceURL)
        let replaced = engine.sizeOnDisk(of: destinationURL)

        do {
            // Remove existing file if present (e.g. partial/corrupt)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            engine.noteWrite(at: destinationURL, replacing: replaced)
        } catch {
            AppLogger.gifConverter.error("Failed to save GIF HEVC to cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clear entire cache
    func clearCache() {
        engine.clear()
    }

    /// Re-check the budget (preset change) and evict if over.
    func enforceBudget() {
        engine.evictIfNeeded()
    }

    /// Get cache statistics
    func getCacheStats() -> (fileCount: Int, totalSize: Int64) {
        engine.stats()
    }
}
