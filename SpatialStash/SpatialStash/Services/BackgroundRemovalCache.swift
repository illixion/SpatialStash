/*
 Spatial Stash - Background Removal Cache

 Persistent cache for background-removed images using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Separate from DiskImageCache to allow independent cache management.
 */

import Foundation
import ImageIO
import os
import UIKit
import UniformTypeIdentifiers

actor BackgroundRemovalCache {
    static let shared = BackgroundRemovalCache()

    private let cacheDirectory: URL
    private let maxCacheSize: Int64 // Maximum cache size in bytes
    private let fileManager = FileManager.default
    private let heicCompressionQuality: CGFloat = 0.95

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

        Task { [self] in
            await migrateLegacyCacheIfNeeded()
        }
    }

    /// Generate a cache key from a URL with background removal suffix.
    /// When `isAutoEnhanced` is true, the key includes an additional suffix
    /// so regular and auto-enhanced variants are stored as separate cache entries.
    private func cacheKey(for url: URL, isAutoEnhanced: Bool = false) -> String {
        var urlString = url.absoluteString + ":backgroundRemoved"
        if isAutoEnhanced {
            urlString += ":autoEnhanced"
        }
        let data = Data(urlString.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Get the file URL for a cached background-removed image
    private func cacheFileURL(for url: URL, isAutoEnhanced: Bool = false) -> URL {
        let key = cacheKey(for: url, isAutoEnhanced: isAutoEnhanced)
        return cacheDirectory.appendingPathComponent(key + ".heic")
    }

    /// Legacy cache file URL (pre-HEIC migration, no extension)
    private func legacyCacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key)
    }

    /// Return cached file URL if present
    func cachedFileURL(for url: URL, isAutoEnhanced: Bool = false) -> URL? {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        // Legacy fallback only applies to regular (non-enhanced) variant
        if !isAutoEnhanced {
            let legacyURL = legacyCacheFileURL(for: url)
            return fileManager.fileExists(atPath: legacyURL.path) ? legacyURL : nil
        }

        return nil
    }

    /// Check if a background-removed image is cached
    func isCached(url: URL, isAutoEnhanced: Bool = false) -> Bool {
        return cachedFileURL(for: url, isAutoEnhanced: isAutoEnhanced) != nil
    }

    /// Load background-removed image data from disk cache
    func loadData(for url: URL, isAutoEnhanced: Bool = false) -> Data? {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)

        if fileManager.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return nil
            }

            // Update access time for LRU tracking
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )

            if let migratedData = migrateDataToHeicIfNeeded(data, destinationURL: fileURL) {
                return migratedData
            }

            return data
        }

        // Legacy fallback only for regular variant
        guard !isAutoEnhanced else { return nil }

        let legacyURL = legacyCacheFileURL(for: url)
        guard fileManager.fileExists(atPath: legacyURL.path),
              let legacyData = try? Data(contentsOf: legacyURL, options: .mappedIfSafe) else {
            return nil
        }

        if let migratedData = migrateLegacyDataToHeic(legacyData, legacyURL: legacyURL, destinationURL: fileURL) {
            return migratedData
        }

        // Update access time for LRU tracking on legacy entry
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: legacyURL.path
        )

        return legacyData
    }

    /// Save background-removed image to disk cache as HEIC
    func saveImage(_ image: UIImage, for url: URL, isAutoEnhanced: Bool = false) {
        let fileURL = cacheFileURL(for: url, isAutoEnhanced: isAutoEnhanced)

        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode background-removed image as HEIC")
            return
        }

        do {
            try heicData.write(to: fileURL)

            // Check cache size and cleanup if needed
            Task { [self] in
                await self.cleanupIfNeeded()
            }
        } catch {
            AppLogger.diskCache.error("Failed to save background-removed image: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Save background-removed image data to disk cache (re-encodes to HEIC)
    func saveData(_ data: Data, for url: URL) {
        guard let image = UIImage(data: data) else {
            AppLogger.diskCache.warning("Failed to decode background-removed image data for HEIC re-encode")
            return
        }

        saveImage(image, for: url)
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

    // MARK: - HEIC Encoding and Migration

    private func encodeHeicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        let orientation = cgImagePropertyOrientation(for: image.imageOrientation)
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heicCompressionQuality,
            kCGImagePropertyOrientation: orientation.rawValue
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func cgImagePropertyOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private func isHeicData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return false
        }

        return type == UTType.heic.identifier || type == UTType.heif.identifier
    }

    private func migrateDataToHeicIfNeeded(_ data: Data, destinationURL: URL) -> Data? {
        guard !isHeicData(data) else { return nil }
        guard let image = UIImage(data: data),
              let heicData = encodeHeicData(from: image) else {
            return nil
        }

        do {
            try heicData.write(to: destinationURL)
            return heicData
        } catch {
            AppLogger.diskCache.warning("Failed to migrate background-removed image to HEIC: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func migrateLegacyDataToHeic(_ data: Data, legacyURL: URL, destinationURL: URL) -> Data? {
        guard let image = UIImage(data: data),
              let heicData = encodeHeicData(from: image) else {
            return nil
        }

        do {
            try heicData.write(to: destinationURL)
            try? fileManager.removeItem(at: legacyURL)
            return heicData
        } catch {
            AppLogger.diskCache.warning("Failed to migrate legacy background removal cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func migrateLegacyCacheIfNeeded() async {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for fileURL in contents {
            if fileURL.pathExtension.lowercased() == "heic" {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }

            let destinationURL = cacheDirectory.appendingPathComponent(fileURL.lastPathComponent + ".heic")
            if migrateLegacyDataToHeic(data, legacyURL: fileURL, destinationURL: destinationURL) != nil {
                continue
            }
        }
    }
}

// CommonCrypto for SHA256 hashing
import CommonCrypto
