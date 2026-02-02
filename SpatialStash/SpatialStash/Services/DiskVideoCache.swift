/*
 Spatial Stash - Disk Video Cache

 Persistent cache for converted MV-HEVC stereoscopic videos.
 Avoids re-downloading and re-converting videos that have already been processed.
 The system can automatically clean this directory when storage is low.
 */

import Foundation
import os

/// Metadata about a cached video
struct CachedVideoMetadata: Codable {
    let videoId: String
    let originalURL: String
    let stereoscopicFormat: String
    let sourceWidth: Int
    let sourceHeight: Int
    let duration: TimeInterval
    let fileSize: Int64
    let cachedDate: Date
}

actor DiskVideoCache {
    static let shared = DiskVideoCache()

    private let cacheDirectory: URL
    private let metadataDirectory: URL
    private let maxCacheSize: Int64 // Maximum cache size in bytes
    private let fileManager = FileManager.default

    private init() {
        // Use the Caches directory - Apple-approved for temporary cache storage
        // System can clean this when storage is low
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("VideoCache", isDirectory: true)
        metadataDirectory = cachesDirectory.appendingPathComponent("VideoCacheMetadata", isDirectory: true)

        // Default max size: 2 GB for video cache (videos are larger than images)
        maxCacheSize = 2 * 1024 * 1024 * 1024

        // Create cache directories if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        // Mark directories as excluded from backups (Apple requirement for caches)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        var mutableMetadataDir = metadataDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)
        try? mutableMetadataDir.setResourceValues(resourceValues)
    }

    /// Generate a cache key from video ID and format
    private func cacheKey(videoId: String, format: String) -> String {
        // Use video ID and format to create unique cache key
        "\(videoId)_\(format)"
    }

    /// Get the file URL for a cached video
    private func cacheFileURL(videoId: String, format: String) -> URL {
        let key = cacheKey(videoId: videoId, format: format)
        return cacheDirectory.appendingPathComponent("\(key).mov")
    }

    /// Get the metadata file URL for a cached video
    private func metadataFileURL(videoId: String, format: String) -> URL {
        let key = cacheKey(videoId: videoId, format: format)
        return metadataDirectory.appendingPathComponent("\(key).json")
    }

    /// Check if a converted video is cached
    func isCached(videoId: String, format: String) -> Bool {
        let fileURL = cacheFileURL(videoId: videoId, format: format)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Get the cached video URL if available
    /// - Parameters:
    ///   - videoId: The unique video identifier
    ///   - format: The stereoscopic format (e.g., "sbs", "ou")
    /// - Returns: URL to the cached file if it exists, nil otherwise
    func getCachedVideoURL(videoId: String, format: String) -> URL? {
        let fileURL = cacheFileURL(videoId: videoId, format: format)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Update access time for LRU tracking
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )

        return fileURL
    }

    /// Save a converted video to the cache
    /// - Parameters:
    ///   - sourceURL: URL of the converted video file to cache
    ///   - videoId: The unique video identifier
    ///   - format: The stereoscopic format
    ///   - metadata: Metadata about the cached video
    /// - Returns: URL to the cached file
    @discardableResult
    func saveVideo(from sourceURL: URL, videoId: String, format: String, metadata: CachedVideoMetadata) throws -> URL {
        let destinationURL = cacheFileURL(videoId: videoId, format: format)
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        // Remove existing file if present
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.removeItem(at: metadataURL)

        // Copy video file to cache
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        // Save metadata
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL)

        // Check cache size and cleanup if needed
        Task { [self] in
            await self.cleanupIfNeeded()
        }

        AppLogger.videoCache.info("Cached video: \(videoId, privacy: .private) (\(format, privacy: .public))")
        return destinationURL
    }

    /// Move a converted video to the cache (more efficient than copy)
    /// - Parameters:
    ///   - sourceURL: URL of the converted video file to cache
    ///   - videoId: The unique video identifier
    ///   - format: The stereoscopic format
    ///   - metadata: Metadata about the cached video
    /// - Returns: URL to the cached file
    @discardableResult
    func moveVideoToCache(from sourceURL: URL, videoId: String, format: String, metadata: CachedVideoMetadata) throws -> URL {
        let destinationURL = cacheFileURL(videoId: videoId, format: format)
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        // Remove existing file if present
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.removeItem(at: metadataURL)

        // Move video file to cache
        try fileManager.moveItem(at: sourceURL, to: destinationURL)

        // Save metadata
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL)

        // Check cache size and cleanup if needed
        Task { [self] in
            await self.cleanupIfNeeded()
        }

        AppLogger.videoCache.info("Cached video (moved): \(videoId, privacy: .private) (\(format, privacy: .public))")
        return destinationURL
    }

    /// Get metadata for a cached video
    func getMetadata(videoId: String, format: String) -> CachedVideoMetadata? {
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedVideoMetadata.self, from: data)
    }

    /// Remove a specific video from cache
    func removeVideo(videoId: String, format: String) {
        let fileURL = cacheFileURL(videoId: videoId, format: format)
        let metadataURL = metadataFileURL(videoId: videoId, format: format)

        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: metadataURL)
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

        AppLogger.videoCache.notice("Cache size (\(currentSize / 1024 / 1024, privacy: .public) MB) exceeds limit, cleaning up...")

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

            // Also remove corresponding metadata file
            let videoFilename = file.url.deletingPathExtension().lastPathComponent
            let metadataURL = metadataDirectory.appendingPathComponent("\(videoFilename).json")

            do {
                try fileManager.removeItem(at: file.url)
                try? fileManager.removeItem(at: metadataURL)
                freedSize += file.size
            } catch {
                AppLogger.videoCache.warning("Failed to remove file: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLogger.videoCache.info("Freed \(freedSize / 1024 / 1024, privacy: .public) MB")
    }

    /// Clear entire cache
    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.removeItem(at: metadataDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        AppLogger.videoCache.notice("Cache cleared")
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

    /// List all cached videos
    func listCachedVideos() -> [CachedVideoMetadata] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents.compactMap { url -> CachedVideoMetadata? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? decoder.decode(CachedVideoMetadata.self, from: data)
        }
    }
}
