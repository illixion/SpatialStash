/*
 Spatial Stash - Disk Animated JPEG XL Cache

 Persistent cache for the *decoded* output of animated JPEG XL files. Decoding
 an animated JXL is expensive — it runs a WebAssembly libjxl build and muxes
 the frames into an APNG — and ImageIO can't do it natively, so without a cache
 every reopen re-runs the full decode (and shows the loading spinner again).
 This caches the muxed APNG (`image/png`) keyed by the source URL so a second
 open displays instantly, mirroring how DiskGIFHEVCCache caches GIF→HEVC output.

 Size accounting and LRU eviction live in the shared LRUDiskCache engine.
 */

import Foundation
import os

actor DiskJXLAnimationCache {
    static let shared = DiskJXLAnimationCache()

    private let engine: LRUDiskCache
    private let fileManager = FileManager.default

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        engine = LRUDiskCache(
            directory: caches.appendingPathComponent("JXLAnimationCache", isDirectory: true),
            domain: .jxlAnimation,
            log: AppLogger.diskCache,
            formatVersion: 1
        )
    }

    private func cacheFileURL(for url: URL) -> URL {
        engine.directory.appendingPathComponent(LRUDiskCache.sha256Key(url.absoluteString) + ".png")
    }

    /// Load the decoded APNG for a source URL, or nil if not cached.
    func loadData(for url: URL) -> Data? {
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        engine.touch(fileURL)
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    /// Save the decoded APNG bytes for a source URL.
    func saveData(_ data: Data, for url: URL) {
        let fileURL = cacheFileURL(for: url)
        let replaced = engine.sizeOnDisk(of: fileURL)
        do {
            try data.write(to: fileURL)
            engine.noteWrite(at: fileURL, replacing: replaced)
        } catch {
            AppLogger.diskCache.error("Failed to save decoded JXL: \(error.localizedDescription, privacy: .public)")
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
