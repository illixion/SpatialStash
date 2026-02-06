/*
 Spatial Stash - Thumbnail Generator

 Memory-efficient thumbnail generation using CGImageSource.
 Uses ImageIO's thumbnail APIs to downsample during decoding,
 avoiding loading full-resolution images into memory.
 */

import Foundation
import ImageIO
import os
import UIKit

/// Memory-efficient thumbnail generator using ImageIO
actor ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    /// Default thumbnail size for gallery views
    static let defaultThumbnailSize: CGFloat = 400 // 2x for 200pt display

    /// Maximum concurrent thumbnail generation tasks
    private let maxConcurrentTasks = 4

    /// Semaphore to limit concurrent operations
    private let semaphore: DispatchSemaphore

    /// In-progress generation tasks to prevent duplicates
    private var inProgressTasks: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        semaphore = DispatchSemaphore(value: maxConcurrentTasks)
    }

    /// Generate a thumbnail for a local file URL
    /// - Parameters:
    ///   - url: The local file URL
    ///   - maxSize: Maximum dimension for the thumbnail (default 400px)
    /// - Returns: A downsampled UIImage, or nil if generation failed
    func generateThumbnail(for url: URL, maxSize: CGFloat = defaultThumbnailSize) async -> UIImage? {
        // Check for in-progress task
        if let existingTask = inProgressTasks[url] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> {
            await withCheckedContinuation { continuation in
                // Use semaphore to limit concurrent operations
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    self.semaphore.wait()
                    defer { self.semaphore.signal() }

                    let thumbnail = self.createThumbnailSync(for: url, maxSize: maxSize)
                    continuation.resume(returning: thumbnail)
                }
            }
        }

        inProgressTasks[url] = task
        let result = await task.value
        inProgressTasks[url] = nil

        return result
    }

    /// Synchronous thumbnail creation using CGImageSource
    private nonisolated func createThumbnailSync(for url: URL, maxSize: CGFloat) -> UIImage? {
        // Create image source from file
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            AppLogger.imageLoader.warning("Failed to create image source for thumbnail: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Configure thumbnail options for memory efficiency
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // Apply orientation
            kCGImageSourceShouldCacheImmediately: true
        ]

        // Generate thumbnail - this downsamples during decode
        guard let thumbnailRef = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            AppLogger.imageLoader.warning("Failed to create thumbnail for: \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        return UIImage(cgImage: thumbnailRef)
    }

    /// Get image dimensions without loading the full image
    nonisolated func getImageDimensions(for url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }

        guard let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        // Check for orientation that swaps dimensions
        if let orientation = properties[kCGImagePropertyOrientation] as? Int {
            // Orientations 5-8 swap width and height
            if orientation >= 5 && orientation <= 8 {
                return CGSize(width: height, height: width)
            }
        }

        return CGSize(width: width, height: height)
    }

    /// Check if a file is an animated GIF without loading the full image
    nonisolated func isAnimatedGIF(at url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }
}
