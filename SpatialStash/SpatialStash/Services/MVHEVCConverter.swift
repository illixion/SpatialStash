/*
 Spatial Stash - MV-HEVC Converter

 Converts SBS/OU stereoscopic video to MV-HEVC format for Vision Pro playback.
 Uses AVFoundation with tagged pixel buffers for stereoscopic encoding.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Accelerate

/// Configuration for MV-HEVC conversion
struct MVHEVCConversionConfig: Sendable {
    let format: StereoscopicFormat
    let outputWidth: Int
    let outputHeight: Int
    let frameRate: Double
    let horizontalFieldOfView: Float
    let horizontalDisparityAdjustment: Float

    /// Whether the left/right eyes are swapped in the source video
    let eyesReversed: Bool

    init(
        format: StereoscopicFormat,
        outputWidth: Int,
        outputHeight: Int,
        frameRate: Double = 30.0,
        horizontalFieldOfView: Float = 90.0,
        horizontalDisparityAdjustment: Float = 0.0,
        eyesReversed: Bool = false
    ) {
        self.format = format
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.frameRate = frameRate
        self.horizontalFieldOfView = horizontalFieldOfView
        self.horizontalDisparityAdjustment = horizontalDisparityAdjustment
        self.eyesReversed = eyesReversed
    }

    /// Create config from video properties
    static func from(
        video: GalleryVideo,
        format: StereoscopicFormat,
        frameRate: Double = 30.0
    ) -> MVHEVCConversionConfig {
        let sourceWidth = video.sourceWidth ?? 3840
        let sourceHeight = video.sourceHeight ?? 1080

        let (perEyeWidth, perEyeHeight) = format.perEyeDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        return MVHEVCConversionConfig(
            format: format,
            outputWidth: perEyeWidth,
            outputHeight: perEyeHeight,
            frameRate: frameRate,
            eyesReversed: video.eyesReversed
        )
    }

    /// Create config from video and custom 3D settings
    static func from(
        video: GalleryVideo,
        settings: Video3DSettings,
        frameRate: Double = 30.0
    ) -> MVHEVCConversionConfig {
        let sourceWidth = video.sourceWidth ?? 3840
        let sourceHeight = video.sourceHeight ?? 1080

        let (perEyeWidth, perEyeHeight) = settings.format.perEyeDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        return MVHEVCConversionConfig(
            format: settings.format,
            outputWidth: perEyeWidth,
            outputHeight: perEyeHeight,
            frameRate: frameRate,
            horizontalFieldOfView: settings.horizontalFieldOfView,
            horizontalDisparityAdjustment: settings.horizontalDisparityAdjustment,
            eyesReversed: settings.eyesReversed
        )
    }
}

/// Result of a chunk conversion
struct ConvertedChunk: Sendable {
    let index: Int
    let fileURL: URL
    let duration: CMTime
    let frameCount: Int
    let isLast: Bool
}

/// Errors during MV-HEVC conversion
enum MVHEVCError: Error, LocalizedError {
    case noVideoTrack
    case pixelBufferCreationFailed
    case conversionFailed(String)
    case unsupportedFormat
    case writerInitFailed(String)
    case readerInitFailed(String)
    case encodingFailed(String)
    case frameSplitFailed
    case simulatorNotSupported

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in source"
        case .pixelBufferCreationFailed:
            return "Failed to create pixel buffer"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        case .unsupportedFormat:
            return "Unsupported video format"
        case .writerInitFailed(let msg):
            return "Failed to initialize writer: \(msg)"
        case .readerInitFailed(let msg):
            return "Failed to initialize reader: \(msg)"
        case .encodingFailed(let msg):
            return "Encoding failed: \(msg)"
        case .frameSplitFailed:
            return "Failed to split stereoscopic frame"
        case .simulatorNotSupported:
            return "MV-HEVC encoding requires a physical device. The visionOS Simulator does not support stereoscopic video encoding."
        }
    }
}

/// Check if running in simulator
private var isSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}

/// Converts SBS/OU video chunks to MV-HEVC format
actor MVHEVCConverter {
    private let tempDirectory: URL
    private let pixelBufferPool: CVPixelBufferPool?

    init() {
        // Create temp directory for converted chunks
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        tempDirectory = cachesDir.appendingPathComponent("MVHEVCChunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Pre-create pixel buffer pool for efficiency
        pixelBufferPool = nil // Will be created per-conversion with correct dimensions
    }

    /// Convert a full video file to MV-HEVC
    /// - Parameters:
    ///   - sourceURL: URL to the source video file
    ///   - config: Conversion configuration
    ///   - videoId: Unique identifier for the video (for file naming)
    ///   - progressHandler: Callback for conversion progress (0.0 to 1.0)
    /// - Returns: URL to the converted MV-HEVC file
    func convertFullVideo(
        sourceURL: URL,
        config: MVHEVCConversionConfig,
        videoId: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // MV-HEVC encoding is not supported in the Simulator
        #if targetEnvironment(simulator)
        throw MVHEVCError.simulatorNotSupported
        #else

        let outputURL = tempDirectory.appendingPathComponent("mvhevc_\(videoId).mov")

        // Clean up any existing output file
        try? FileManager.default.removeItem(at: outputURL)

        // Setup asset reader
        let asset = AVURLAsset(url: sourceURL)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MVHEVCError.noVideoTrack
        }

        // Get actual frame rate and duration from source
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let actualFrameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : config.frameRate

        let duration = try await asset.load(.duration)
        let totalFrames = Int(duration.seconds * actualFrameRate)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MVHEVCError.readerInitFailed(error.localizedDescription)
        }

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw MVHEVCError.readerInitFailed("Cannot add reader output")
        }
        reader.add(readerOutput)

        // Setup asset writer with MV-HEVC
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw MVHEVCError.writerInitFailed(error.localizedDescription)
        }

        let videoSettings = createMVHEVCVideoSettings(config: config)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Create tagged buffer adaptor for stereo frames
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.outputWidth,
            kCVPixelBufferHeightKey as String: config.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw MVHEVCError.writerInitFailed("Cannot add writer input")
        }
        writer.add(writerInput)

        // Start processing
        guard reader.startReading() else {
            throw MVHEVCError.readerInitFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        guard writer.startWriting() else {
            throw MVHEVCError.writerInitFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        writer.startSession(atSourceTime: .zero)

        // Process frames
        var frameCount = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFrameRate))

        while reader.status == .reading {
            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            // Split frame into left and right eye
            let (leftEye, rightEye) = try splitStereoFrame(
                pixelBuffer: pixelBuffer,
                format: config.format,
                outputWidth: config.outputWidth,
                outputHeight: config.outputHeight
            )

            // Create tagged buffers and append
            // If eyes are reversed in source, swap left and right
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))

            let taggedBuffers: [CMTaggedBuffer]
            if config.eyesReversed {
                // Swap: what was extracted as "left" is actually right eye, and vice versa
                taggedBuffers = createTaggedBuffers(
                    leftEye: rightEye,
                    rightEye: leftEye
                )
            } else {
                taggedBuffers = createTaggedBuffers(
                    leftEye: leftEye,
                    rightEye: rightEye
                )
            }

            guard adaptor.appendTaggedBuffers(taggedBuffers, withPresentationTime: presentationTime) else {
                throw MVHEVCError.encodingFailed("Failed to append frame \(frameCount)")
            }

            frameCount += 1

            // Report progress every 10 frames
            if frameCount % 10 == 0 {
                let progress = totalFrames > 0 ? Double(frameCount) / Double(totalFrames) : 0
                progressHandler(min(progress, 1.0))
            }
        }

        // Finish writing
        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw MVHEVCError.encodingFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        progressHandler(1.0)
        return outputURL
        #endif
    }

    /// Convert a downloaded chunk to MV-HEVC (legacy method for chunked approach)
    /// - Parameters:
    ///   - chunkData: Raw video data from the chunk
    ///   - chunkIndex: Index of this chunk
    ///   - config: Conversion configuration
    ///   - videoId: Unique identifier for the video (for file naming)
    /// - Returns: Information about the converted chunk
    func convert(
        chunkData: Data,
        chunkIndex: Int,
        config: MVHEVCConversionConfig,
        videoId: String
    ) async throws -> ConvertedChunk {
        // Write chunk data to temp file for AVAssetReader
        let inputURL = tempDirectory.appendingPathComponent("input_\(videoId)_\(chunkIndex).mp4")
        let outputURL = tempDirectory.appendingPathComponent("mvhevc_\(videoId)_\(chunkIndex).mov")

        // Clean up any existing files
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)

        try chunkData.write(to: inputURL)

        defer {
            // Clean up input file after conversion
            try? FileManager.default.removeItem(at: inputURL)
        }

        // Setup asset reader
        let asset = AVURLAsset(url: inputURL)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MVHEVCError.noVideoTrack
        }

        // Get actual frame rate from source
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let actualFrameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : config.frameRate

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MVHEVCError.readerInitFailed(error.localizedDescription)
        }

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw MVHEVCError.readerInitFailed("Cannot add reader output")
        }
        reader.add(readerOutput)

        // Setup asset writer with MV-HEVC
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw MVHEVCError.writerInitFailed(error.localizedDescription)
        }

        let videoSettings = createMVHEVCVideoSettings(config: config)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Create tagged buffer adaptor for stereo frames
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.outputWidth,
            kCVPixelBufferHeightKey as String: config.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw MVHEVCError.writerInitFailed("Cannot add writer input")
        }
        writer.add(writerInput)

        // Start processing
        guard reader.startReading() else {
            throw MVHEVCError.readerInitFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        guard writer.startWriting() else {
            throw MVHEVCError.writerInitFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        writer.startSession(atSourceTime: .zero)

        // Process frames
        var frameCount = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFrameRate))

        while reader.status == .reading {
            guard writerInput.isReadyForMoreMediaData else {
                // Wait a bit if writer isn't ready
                try await Task.sleep(for: .milliseconds(10))
                continue
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }

            // Split frame into left and right eye
            let (leftEye, rightEye) = try splitStereoFrame(
                pixelBuffer: pixelBuffer,
                format: config.format,
                outputWidth: config.outputWidth,
                outputHeight: config.outputHeight
            )

            // Create tagged buffers and append
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))

            let taggedBuffers = createTaggedBuffers(
                leftEye: leftEye,
                rightEye: rightEye
            )

            guard adaptor.appendTaggedBuffers(taggedBuffers, withPresentationTime: presentationTime) else {
                throw MVHEVCError.encodingFailed("Failed to append frame \(frameCount)")
            }

            frameCount += 1
        }

        // Finish writing
        writerInput.markAsFinished()

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw MVHEVCError.encodingFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        let duration = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))

        return ConvertedChunk(
            index: chunkIndex,
            fileURL: outputURL,
            duration: duration,
            frameCount: frameCount,
            isLast: false // Set by caller based on chunk info
        )
    }

    /// Create video settings for MV-HEVC output
    private func createMVHEVCVideoSettings(config: MVHEVCConversionConfig) -> [String: Any] {
        // MV-HEVC requires specific compression properties
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: 20_000_000, // 20 Mbps total
            AVVideoExpectedSourceFrameRateKey: config.frameRate,
            AVVideoMaxKeyFrameIntervalKey: Int(config.frameRate), // Keyframe every second
        ]

        // MV-HEVC specific properties for stereoscopic encoding
        // Layer IDs: 0 = left eye (base), 1 = right eye (enhancement)
        // These are REQUIRED for visionOS to recognize the video as stereoscopic
        compressionProperties[kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String] = [0, 1] as CFArray

        // Horizontal field of view - CRITICAL for spatial video recognition
        // Value is in thousandths of a degree (e.g., 90000 = 90 degrees)
        let horizontalFOVInThousandths = Int(config.horizontalFieldOfView * 1000)
        compressionProperties[kCMFormatDescriptionExtension_HorizontalFieldOfView as String] = horizontalFOVInThousandths

        // Horizontal disparity adjustment (positive = more depth, typical range 0-500)
        let disparityAdjustment = config.horizontalDisparityAdjustment != 0.0 ? Int(config.horizontalDisparityAdjustment) : 200
        compressionProperties[kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String] = disparityAdjustment

        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: config.outputWidth,
            AVVideoHeightKey: config.outputHeight,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }

    /// Split SBS or OU frame into left and right eye buffers
    private func splitStereoFrame(
        pixelBuffer: CVPixelBuffer,
        format: StereoscopicFormat,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> (left: CVPixelBuffer, right: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Calculate source regions based on format
        let leftRect: CGRect
        let rightRect: CGRect

        switch format {
        case .sideBySide, .halfSideBySide:
            // Left half | Right half
            let halfWidth = CGFloat(sourceWidth) / 2
            leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: CGFloat(sourceHeight))
            rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: CGFloat(sourceHeight))

        case .overUnder, .halfOverUnder:
            // Top (left eye) / Bottom (right eye)
            let halfHeight = CGFloat(sourceHeight) / 2
            leftRect = CGRect(x: 0, y: 0, width: CGFloat(sourceWidth), height: halfHeight)
            rightRect = CGRect(x: 0, y: halfHeight, width: CGFloat(sourceWidth), height: halfHeight)
        }

        // Create output buffers
        let leftBuffer = try createPixelBuffer(width: outputWidth, height: outputHeight)
        let rightBuffer = try createPixelBuffer(width: outputWidth, height: outputHeight)

        // Copy and scale regions using vImage
        try copyAndScaleRegion(from: pixelBuffer, rect: leftRect, to: leftBuffer)
        try copyAndScaleRegion(from: pixelBuffer, rect: rightRect, to: rightBuffer)

        return (leftBuffer, rightBuffer)
    }

    /// Create a pixel buffer with specified dimensions
    private func createPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw MVHEVCError.pixelBufferCreationFailed
        }
        return buffer
    }

    /// Copy and scale a region from source to destination using vImage
    private func copyAndScaleRegion(
        from source: CVPixelBuffer,
        rect: CGRect,
        to destination: CVPixelBuffer
    ) throws {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let srcBaseAddress = CVPixelBufferGetBaseAddress(source),
              let dstBaseAddress = CVPixelBufferGetBaseAddress(destination) else {
            throw MVHEVCError.frameSplitFailed
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let dstWidth = CVPixelBufferGetWidth(destination)
        let dstHeight = CVPixelBufferGetHeight(destination)

        // Calculate source region pointer
        let srcX = Int(rect.origin.x)
        let srcY = Int(rect.origin.y)
        let srcRegionWidth = Int(rect.width)
        let srcRegionHeight = Int(rect.height)

        // Offset to the start of the region
        let srcRegionStart = srcBaseAddress.advanced(by: srcY * srcBytesPerRow + srcX * 4)

        // Create vImage buffers
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: srcRegionStart),
            height: vImagePixelCount(srcRegionHeight),
            width: vImagePixelCount(srcRegionWidth),
            rowBytes: srcBytesPerRow
        )

        var dstBuffer = vImage_Buffer(
            data: dstBaseAddress,
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: dstBytesPerRow
        )

        // Scale the region to fit the destination
        let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))

        if error != kvImageNoError {
            throw MVHEVCError.frameSplitFailed
        }
    }

    /// Create tagged buffers for stereo frames
    private func createTaggedBuffers(
        leftEye: CVPixelBuffer,
        rightEye: CVPixelBuffer
    ) -> [CMTaggedBuffer] {
        // Create tagged buffers with video layer IDs and stereo view tags
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye)]

        let leftTaggedBuffer = CMTaggedBuffer(tags: leftTags, pixelBuffer: leftEye)
        let rightTaggedBuffer = CMTaggedBuffer(tags: rightTags, pixelBuffer: rightEye)

        return [leftTaggedBuffer, rightTaggedBuffer]
    }

    /// Cleanup temporary files for a specific video
    func cleanup(videoId: String) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for url in contents where url.lastPathComponent.contains(videoId) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Cleanup all temporary files
    func cleanupAll() {
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    /// Get the temp directory URL (for debugging)
    var tempDirectoryURL: URL {
        tempDirectory
    }
}
