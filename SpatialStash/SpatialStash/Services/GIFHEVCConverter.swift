/*
 Spatial Stash - GIF HEVC Converter

 Converts animated GIF data to HEVC .mp4 video for reliable multi-window
 playback on visionOS. Frames are extracted via CGImageSource and encoded
 using AVAssetWriter with the HEVC codec. Variable frame timing from the
 source GIF is preserved.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import UIKit

actor GIFHEVCConverter {
    static let shared = GIFHEVCConverter()

    enum ConversionError: Error, LocalizedError {
        case invalidGIFData
        case noFrames
        case pixelBufferCreationFailed
        case writerSetupFailed(String)
        case encodingFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidGIFData: return "Invalid GIF data"
            case .noFrames: return "GIF contains no frames"
            case .pixelBufferCreationFailed: return "Failed to create pixel buffer"
            case .writerSetupFailed(let msg): return "Writer setup failed: \(msg)"
            case .encodingFailed(let msg): return "Encoding failed: \(msg)"
            case .cancelled: return "Conversion was cancelled"
            }
        }
    }

    private init() {}

    // MARK: - Public API

    /// Convert GIF data to HEVC .mp4, returning a cached file URL.
    /// Returns immediately if the result is already cached.
    func convert(gifData: Data, sourceURL: URL) async throws -> URL {
        // Check cache first
        if let cachedURL = await DiskGIFHEVCCache.shared.cachedFileURL(for: sourceURL) {
            AppLogger.gifConverter.debug("Cache hit for GIF HEVC: \(sourceURL.lastPathComponent, privacy: .public)")
            return cachedURL
        }

        AppLogger.gifConverter.info("Converting GIF to HEVC: \(sourceURL.lastPathComponent, privacy: .public)")

        // Extract frames from GIF
        guard let imageSource = CGImageSourceCreateWithData(gifData as CFData, nil) else {
            throw ConversionError.invalidGIFData
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else {
            throw ConversionError.noFrames
        }

        // Get dimensions from first frame
        guard let firstImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.noFrames
        }
        let width = firstImage.width
        let height = firstImage.height

        // Create temporary output file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        do {
            try await encodeFrames(
                imageSource: imageSource,
                frameCount: frameCount,
                width: width,
                height: height,
                outputURL: tempURL
            )

            // Move to cache
            await DiskGIFHEVCCache.shared.saveFile(from: tempURL, for: sourceURL)

            guard let cachedURL = await DiskGIFHEVCCache.shared.cachedFileURL(for: sourceURL) else {
                throw ConversionError.encodingFailed("File not found in cache after save")
            }

            AppLogger.gifConverter.info("GIF HEVC conversion complete: \(frameCount, privacy: .public) frames, \(width, privacy: .public)x\(height, privacy: .public)")
            return cachedURL
        } catch {
            // Clean up temp file on error
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Encoding

    private func encodeFrames(
        imageSource: CGImageSource,
        frameCount: Int,
        width: Int,
        height: Int,
        outputURL: URL
    ) async throws {
        // Set up AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ConversionError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: calculateBitrate(width: width, height: height),
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let sourcePixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw ConversionError.writerSetupFailed("Cannot add video input to writer")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw ConversionError.writerSetupFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Encode each frame
        var presentationTime = CMTime.zero

        for frameIndex in 0..<frameCount {
            // Check for cancellation
            if Task.isCancelled {
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw ConversionError.cancelled
            }

            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else {
                continue
            }

            let frameDuration = frameDuration(for: imageSource, at: frameIndex)

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            guard let pixelBuffer = createPixelBuffer(from: cgImage, width: width, height: height) else {
                throw ConversionError.pixelBufferCreationFailed
            }

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw ConversionError.encodingFailed(
                    "Failed to append frame \(frameIndex): \(writer.error?.localizedDescription ?? "unknown")"
                )
            }

            presentationTime = CMTimeAdd(presentationTime, frameDuration)
        }

        writerInput.markAsFinished()

        await writer.finishWriting()

        if writer.status == .failed {
            throw ConversionError.encodingFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
    }

    // MARK: - Frame Timing

    private func frameDuration(for source: CGImageSource, at index: Int) -> CMTime {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return CMTime(value: 1, timescale: 10) // Default 0.1s
        }

        // Prefer unclamped delay time, fall back to standard delay time
        var delay: Double = 0.1
        if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.01 {
            delay = unclamped
        } else if let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0.01 {
            delay = clamped
        }

        // Browser behavior: clamp very short delays to 0.1s
        if delay <= 0.01 {
            delay = 0.1
        }

        // Convert to CMTime with millisecond precision
        return CMTime(value: CMTimeValue(delay * 1000), timescale: 1000)
    }

    // MARK: - Pixel Buffer

    private func createPixelBuffer(from cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // Black background for GIF transparency
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw the frame scaled to fill
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    // MARK: - Bitrate

    private func calculateBitrate(width: Int, height: Int) -> Int {
        // Scale bitrate with resolution; GIFs are typically small
        // Minimum 2 Mbps, scale up for larger dimensions
        return max(2_000_000, width * height * 4)
    }
}
