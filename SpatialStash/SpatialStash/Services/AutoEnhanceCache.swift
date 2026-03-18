/*
 Spatial Stash - Auto Enhance Cache

 Persistent cache for auto-enhanced images using Apple's Caches directory.
 The system can automatically clean this directory when storage is low.
 Mirrors the BackgroundRemovalCache pattern for consistent behavior.
 */

import CommonCrypto
import Foundation
import ImageIO
import os
import UIKit
import UniformTypeIdentifiers

actor AutoEnhanceCache {
    static let shared = AutoEnhanceCache()

    private let cacheDirectory: URL
    private let maxCacheSize: Int64
    private let fileManager = FileManager.default
    private let heicCompressionQuality: CGFloat = 0.95

    private init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("AutoEnhanceCache", isDirectory: true)

        // Default max size: 2000 MB
        maxCacheSize = 2000 * 1024 * 1024

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableCacheDir = cacheDirectory
        try? mutableCacheDir.setResourceValues(resourceValues)
    }

    // MARK: - Cache Key

    private func cacheKey(for url: URL) -> String {
        let urlString = url.absoluteString + ":autoEnhanced"
        let data = Data(urlString.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheFileURL(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key + ".heic")
    }

    // MARK: - Load / Save

    func isCached(url: URL) -> Bool {
        fileManager.fileExists(atPath: cacheFileURL(for: url).path)
    }

    func loadData(for url: URL) -> Data? {
        let fileURL = cacheFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }

        // Update access time for LRU tracking
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )

        return data
    }

    func saveImage(_ image: UIImage, for url: URL) {
        guard let heicData = encodeHeicData(from: image) else {
            AppLogger.diskCache.warning("Failed to encode auto-enhanced image as HEIC")
            return
        }

        let fileURL = cacheFileURL(for: url)
        do {
            try heicData.write(to: fileURL)
            Task { [self] in await self.cleanupIfNeeded() }
        } catch {
            AppLogger.diskCache.error("Failed to save auto-enhanced image: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cache Management

    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        AppLogger.diskCache.notice("Auto-enhance cache cleared")
    }

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

    // MARK: - Private

    private func cleanupIfNeeded() {
        let currentSize = getCacheSize()
        guard currentSize > maxCacheSize else { return }

        AppLogger.diskCache.notice("Auto-enhance cache size (\(currentSize / 1024 / 1024, privacy: .public) MB) exceeds limit, cleaning up...")

        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, date: Date)] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if let rv = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let fileSize = rv.fileSize, let modDate = rv.contentModificationDate {
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
                AppLogger.diskCache.warning("Failed to remove auto-enhance cache file: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLogger.diskCache.info("Auto-enhance cache freed \(freedSize / 1024 / 1024, privacy: .public) MB")
    }

    private func getCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let rv = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = rv.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    private func encodeHeicData(from image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }

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
}
