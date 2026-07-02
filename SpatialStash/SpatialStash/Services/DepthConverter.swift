/*
 Spatial Stash - Offline Depth Converter

 Pre-processes a video for cached fake-3D playback: decodes every frame, runs
 monocular depth inference, and writes a compact HEVC grayscale depth video
 (depth in luma, source PTS preserved) plus per-frame display-mapping metadata
 into a DepthCacheStore entry.

 Being offline buys quality the realtime path can't have:
 - Lookahead temporal smoothing: each encoded frame is a weighted average of the
   blurred depth of the center frame ±2, so there's zero lag (a causal EMA always
   trails motion) and no ghosting (the window is truncated at scene cuts).
 - Flicker-free normalization: raw model output has an arbitrary per-frame scale.
   Each frame is encoded against its own robust range (p2–p98 from a GPU
   histogram), and a post-pass over the whole video computes a lookahead-smoothed
   display range per frame (segmented at cuts: snap, don't lerp). Playback maps
   stored luma → display depth with a single per-frame scale/bias — no pumping.

 All GPU + inference work runs on a dedicated background queue at .utility QoS
 (never the main thread — compositor watchdog). Roughly 0.5-1x realtime,
 dominated by ANE inference.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os

enum DepthConversionError: Error, LocalizedError {
    case noVideoTrack
    case noDepthModel
    case gpuSetupFailed
    case readerInitFailed(String)
    case writerInitFailed(String)
    case inferenceFailed
    case encodingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found in source"
        case .noDepthModel: return "No depth model installed"
        case .gpuSetupFailed: return "Failed to set up GPU pipelines"
        case .readerInitFailed(let msg): return "Failed to read source video: \(msg)"
        case .writerInitFailed(let msg): return "Failed to create depth video: \(msg)"
        case .inferenceFailed: return "Depth inference failed"
        case .encodingFailed(let msg): return "Depth encoding failed: \(msg)"
        case .cancelled: return "Conversion cancelled"
        }
    }
}

/// CPU mirror of the Metal `DepthHistogramParams` struct.
private struct DepthHistogramParams {
    var lo: Float
    var invSpan: Float
}

/// CPU mirror of the Metal `DepthGuideParams` struct (2 float2s).
private struct DepthGuideParams {
    var uvScale: SIMD2<Float>
    var uvOffset: SIMD2<Float>
}

/// CPU mirror of the Metal `DepthEncodeParams` struct (2 floats + float[5]).
private struct DepthEncodeParams {
    var rangeLo: Float
    var rangeInvSpan: Float
    var weights: (Float, Float, Float, Float, Float)
}

final class DepthConverter: @unchecked Sendable {
    struct Request: Sendable {
        let videoIdentity: String
        let title: String?
        /// Must be a local file — AVAssetReader can't read remote/streamed assets.
        let localFileURL: URL
    }

    struct Output: Sendable {
        let directory: URL
        let meta: DepthCacheStore.Meta
    }

    // MARK: Tuning constants

    /// Decode target: frames are downscaled at decode time to fit within this
    /// (never upscaled). Inference input is ~518px, so decoding 4K frames at
    /// full size would waste most of the decode + Vision-rescale time; 2x the
    /// model input keeps headroom for the edge-aware guide filter.
    private static let maxDecodeDimension = 1036
    /// Temporal window half-width (frames). ±2 → 5-tap centered average.
    private static let temporalRadius = 2
    /// Binomial weights for the ±2 window, truncated at cuts and renormalized.
    private static let temporalBaseWeights: [Float] = [1, 4, 6, 4, 1]
    /// Robust per-frame range percentiles (clips depth outliers/speckle).
    private static let rangeLoPercentile: Float = 0.02
    private static let rangeHiPercentile: Float = 0.98
    /// Display-range smoothing half-width (frames) within a segment (~1s at 30fps
    /// each way). Wider = steadier range, slower adaptation to gradual changes.
    private static let rangeSmoothingRadius = 30
    /// Edge-aware refinement: joint-bilateral radius/sigmas. The spatial term
    /// band-limits depth for the warp grid; the luma term pins depth edges to
    /// image edges (kills silhouette halos on crisp CG content).
    private static let bilateralRadius: Int32 = 5
    private static let bilateralSigmaSpatial: Float = 2.5
    private static let bilateralSigmaLuma: Float = 0.06
    /// Scene-cut detection: total-variation distance between consecutive frames'
    /// normalized depth histograms, plus raw-range jump checks. A cut both
    /// truncates the temporal window and snaps the display range.
    private static let cutShapeDistance: Float = 0.5
    private static let cutRangeRatioBounds: ClosedRange<Float> = 0.6...1.667
    private static let cutRangeLoJump: Float = 0.35
    /// Depth is smooth, low-entropy content; 2 Mbps HEVC at ~518px is generous.
    /// (If banding ever shows on-device, bump to 10-bit x420 instead of bitrate.)
    private static let depthVideoBitrate = 2_000_000

    private let queue = DispatchQueue(label: "com.spatialstash.depth-converter", qos: .utility)
    private let cancelLock = NSLock()
    private var _cancelled = false
    private let signposter = AppLogger.pseudo3DSignposter

    /// Thread-safe; an in-flight conversion notices within one frame.
    func cancel() {
        cancelLock.lock()
        _cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _cancelled
    }

    // MARK: Entry point

    /// Convert a local video into a depth cache entry. Progress is 0-1 across
    /// the whole conversion. Throws `DepthConversionError.cancelled` on cancel;
    /// the partial entry directory is always removed on failure/cancel.
    func convert(request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        // Async metadata loads up front; the frame loop itself is synchronous on
        // the converter queue.
        let asset = AVURLAsset(url: request.localFileURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw DepthConversionError.noVideoTrack
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let duration = (try? await asset.load(.duration)) ?? .zero

        let plan = Plan(
            request: request,
            asset: asset,
            track: track,
            naturalSize: naturalSize,
            frameRate: nominalFrameRate > 0 ? Double(nominalFrameRate) : 30,
            duration: duration
        )
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(plan, progress: progress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Everything `run` needs, resolved before hopping onto the converter queue.
    /// @unchecked: AVAsset/AVAssetTrack are only touched from the converter queue
    /// after this point.
    private struct Plan: @unchecked Sendable {
        let request: Request
        let asset: AVURLAsset
        let track: AVAssetTrack
        let naturalSize: CGSize
        let frameRate: Double
        let duration: CMTime
    }

    // MARK: GPU context

    private struct GPUContext {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let minMaxPipeline: MTLComputePipelineState
        let histogramPipeline: MTLComputePipelineState
        let guidePipeline: MTLComputePipelineState
        let bilateralHPipeline: MTLComputePipelineState
        let bilateralVPipeline: MTLComputePipelineState
        let encodePipeline: MTLComputePipelineState
        let textureCache: CVMetalTextureCache
    }

    private func makeGPUContext() -> GPUContext? {
        guard let device = MetalImageRenderer.shared?.device else { return nil }
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let minMax = pipeline("depthMinMaxReduce"),
              let histogram = pipeline("depthHistogram256"),
              let guide = pipeline("depthGuideLuma"),
              let bilateralH = pipeline("depthJointBilateralH"),
              let bilateralV = pipeline("depthJointBilateralV"),
              let encode = pipeline("depthTemporalEncode"),
              let cache else { return nil }
        return GPUContext(
            device: device, commandQueue: commandQueue,
            minMaxPipeline: minMax, histogramPipeline: histogram,
            guidePipeline: guide, bilateralHPipeline: bilateralH, bilateralVPipeline: bilateralV,
            encodePipeline: encode,
            textureCache: cache
        )
    }

    // MARK: Conversion (converter queue)

    private struct FrameStat {
        let pts: CMTime
        var lo: Float      // robust range (raw units)
        var hi: Float
        var median: Float  // raw units
        var cutBefore: Bool
    }

    private func run(_ plan: Plan, progress: @escaping @Sendable (Double) -> Void) throws -> Output {
        guard let gpu = makeGPUContext() else { throw DepthConversionError.gpuSetupFailed }
        guard let provider = CoreMLDepthProvider(device: gpu.device) else {
            throw DepthConversionError.noDepthModel
        }

        let directory = DepthCacheStore.entryDirectory(
            videoIdentity: plan.request.videoIdentity, modelName: provider.modelName
        )
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DepthConversionError.writerInitFailed(error.localizedDescription)
        }

        do {
            let output = try runConversion(plan, provider: provider, gpu: gpu, directory: directory, progress: progress)
            return output
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private func runConversion(
        _ plan: Plan,
        provider: CoreMLDepthProvider,
        gpu: GPUContext,
        directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Output {
        // Reader: BGRA, downscaled at decode time (aspect-preserving, no upscale).
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: plan.asset)
        } catch {
            throw DepthConversionError.readerInitFailed(error.localizedDescription)
        }
        var readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        if plan.naturalSize.width > 0, plan.naturalSize.height > 0 {
            let maxSide = max(plan.naturalSize.width, plan.naturalSize.height)
            let scale = min(1, CGFloat(Self.maxDecodeDimension) / maxSide)
            readerSettings[kCVPixelBufferWidthKey as String] = Int(plan.naturalSize.width * scale) & ~1
            readerSettings[kCVPixelBufferHeightKey as String] = Int(plan.naturalSize.height * scale) & ~1
        }
        let readerOutput = AVAssetReaderTrackOutput(track: plan.track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw DepthConversionError.readerInitFailed("Cannot add reader output")
        }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw DepthConversionError.readerInitFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        // Per-video state; the writer and GPU scratch are sized from the first
        // frame (decode dims and model output dims aren't known until then).
        var stats: [FrameStat] = []
        var ring: [MTLTexture] = []          // 5-slot refined raw-depth ring
        var scratch: MTLTexture?
        var guideTex: MTLTexture?            // luma guide for the joint bilateral
        var guideParams = DepthGuideParams(uvScale: SIMD2(1, 1), uvOffset: SIMD2(0, 0))
        var partialsBuffer: MTLBuffer?
        var partialsCount = 0
        guard let binsBuffer = gpu.device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw DepthConversionError.gpuSetupFailed
        }
        var prevShape: [Float]?
        var decodedWidth = 0
        var decodedHeight = 0
        var depthWidth = 0
        var depthHeight = 0
        var evenWidth = 0
        var evenHeight = 0
        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var nextEmit = 0

        let totalFrames = max(1, Int(plan.duration.seconds * plan.frameRate))

        // MARK: per-frame helpers

        func dispatch2D(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        }

        /// GPU min/max over the raw map (threadgroup partials folded on CPU).
        func rawMinMax(of rawTex: MTLTexture) throws -> (lo: Float, hi: Float) {
            let groupsX = (rawTex.width + 15) / 16
            let groupsY = (rawTex.height + 15) / 16
            let needed = groupsX * groupsY
            if partialsBuffer == nil || partialsCount < needed {
                partialsBuffer = gpu.device.makeBuffer(length: needed * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
                partialsCount = needed
            }
            guard let partials = partialsBuffer,
                  let cmd = gpu.commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw DepthConversionError.gpuSetupFailed
            }
            enc.setComputePipelineState(gpu.minMaxPipeline)
            enc.setTexture(rawTex, index: 0)
            enc.setBuffer(partials, offset: 0, index: 0)
            dispatch2D(enc, width: rawTex.width, height: rawTex.height)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            var lo = Float.infinity
            var hi = -Float.infinity
            let ptr = partials.contents().bindMemory(to: SIMD2<Float>.self, capacity: needed)
            for i in 0..<needed {
                lo = min(lo, ptr[i].x)
                hi = max(hi, ptr[i].y)
            }
            guard lo.isFinite, hi.isFinite else { return (0, 1) }
            return (lo, hi)
        }

        /// 256-bin histogram over [lo, hi]; returns raw bin counts.
        func histogram(of rawTex: MTLTexture, lo: Float, hi: Float) throws -> [UInt32] {
            memset(binsBuffer.contents(), 0, 256 * MemoryLayout<UInt32>.stride)
            var params = DepthHistogramParams(lo: lo, invSpan: 1 / max(hi - lo, 1e-6))
            guard let cmd = gpu.commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw DepthConversionError.gpuSetupFailed
            }
            enc.setComputePipelineState(gpu.histogramPipeline)
            enc.setTexture(rawTex, index: 0)
            enc.setBuffer(binsBuffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<DepthHistogramParams>.stride, index: 1)
            dispatch2D(enc, width: rawTex.width, height: rawTex.height)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()

            let ptr = binsBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
            return Array(UnsafeBufferPointer(start: ptr, count: 256))
        }

        /// Value at quantile q, linearly interpolated within the bin.
        func percentile(_ bins: [UInt32], total: Int, q: Float, lo: Float, hi: Float) -> Float {
            guard total > 0 else { return lo }
            let target = Float(total) * q
            var cumulative: Float = 0
            for (i, count) in bins.enumerated() where count > 0 {
                let next = cumulative + Float(count)
                if next >= target {
                    let frac = (target - cumulative) / Float(count)
                    return lo + (Float(i) + frac) / 256 * (hi - lo)
                }
                cumulative = next
            }
            return hi
        }

        /// Edge-aware refinement of the raw map into a ring slot: luma guide
        /// from the video frame, then a separable joint bilateral — smooths
        /// depth within regions while pinning its edges to image edges. (No
        /// temporal EMA here; the temporal window is applied at encode time
        /// with lookahead.)
        func refine(rawTex: MTLTexture, videoFrame: CVPixelBuffer, into dest: MTLTexture) throws {
            guard let scratch, let guideTex,
                  let cmd = gpu.commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw DepthConversionError.gpuSetupFailed
            }
            // BGRA texture view of the decoded frame (kept alive across the wait).
            var cvVideoTexture: CVMetalTexture?
            let videoWidth = CVPixelBufferGetWidth(videoFrame)
            let videoHeight = CVPixelBufferGetHeight(videoFrame)
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, gpu.textureCache, videoFrame, nil, .bgra8Unorm, videoWidth, videoHeight, 0, &cvVideoTexture
            ) == kCVReturnSuccess, let cvVideoTexture, let videoTex = CVMetalTextureGetTexture(cvVideoTexture) else {
                throw DepthConversionError.gpuSetupFailed
            }

            var params = DepthStabilizeParams(
                blurRadius: Self.bilateralRadius, blurSigma: Self.bilateralSigmaSpatial,
                baseAlpha: 1, motionGain: 0, hasPrev: 0, sigmaLuma: Self.bilateralSigmaLuma
            )
            enc.setComputePipelineState(gpu.guidePipeline)
            enc.setTexture(videoTex, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setBytes(&guideParams, length: MemoryLayout<DepthGuideParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)

            enc.setComputePipelineState(gpu.bilateralHPipeline)
            enc.setTexture(rawTex, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setTexture(scratch, index: 2)
            enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)

            enc.setComputePipelineState(gpu.bilateralVPipeline)
            enc.setTexture(scratch, index: 0)
            enc.setTexture(guideTex, index: 1)
            enc.setTexture(dest, index: 2)
            enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
            dispatch2D(enc, width: depthWidth, height: depthHeight)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            withExtendedLifetime(cvVideoTexture) {}
        }

        /// Emit the temporally smoothed depth frame centered on stats index `c`.
        /// `lastAvailable` is the newest processed frame index.
        func emit(center c: Int, lastAvailable: Int) throws {
            guard let writerInput, let adaptor, let pool = adaptor.pixelBufferPool else {
                throw DepthConversionError.writerInitFailed("Writer not ready")
            }

            // Window ±2 truncated at cuts: j joins iff no cutBefore flag lies
            // strictly between it and the center.
            var textures: [MTLTexture] = []
            var weights: [Float] = []
            let centerTex = ring[c % ring.count]
            for i in 0..<(2 * Self.temporalRadius + 1) {
                let j = c - Self.temporalRadius + i
                var included = j >= 0 && j <= lastAvailable
                if included, j != c {
                    let crossed = (min(j, c) + 1)...max(j, c)
                    included = !stats[crossed].contains { $0.cutBefore }
                }
                textures.append(included ? ring[j % ring.count] : centerTex)
                weights.append(included ? Self.temporalBaseWeights[i] : 0)
            }
            let weightSum = weights.reduce(0, +)
            guard weightSum > 0 else { throw DepthConversionError.encodingFailed("Empty temporal window") }
            let w = weights.map { $0 / weightSum }

            var pixelBufferOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut) == kCVReturnSuccess,
                  let pixelBuffer = pixelBufferOut else {
                throw DepthConversionError.encodingFailed("Pixel buffer allocation failed")
            }

            // Neutral chroma (CPU), then GPU-write the luma plane in place.
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                memset(chroma, 0x80, rows * bytesPerRow)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            var cvTexture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, gpu.textureCache, pixelBuffer, nil, .r8Unorm, evenWidth, evenHeight, 0, &cvTexture
            ) == kCVReturnSuccess, let cvTexture, let lumaTex = CVMetalTextureGetTexture(cvTexture) else {
                throw DepthConversionError.encodingFailed("Luma texture view failed")
            }

            let stat = stats[c]
            var params = DepthEncodeParams(
                rangeLo: stat.lo,
                rangeInvSpan: 1 / max(stat.hi - stat.lo, 1e-6),
                weights: (w[0], w[1], w[2], w[3], w[4])
            )
            guard let cmd = gpu.commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw DepthConversionError.gpuSetupFailed
            }
            enc.setComputePipelineState(gpu.encodePipeline)
            enc.setTextures(textures, range: 0..<5)
            enc.setTexture(lumaTex, index: 5)
            enc.setBytes(&params, length: MemoryLayout<DepthEncodeParams>.stride, index: 0)
            dispatch2D(enc, width: evenWidth, height: evenHeight)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            withExtendedLifetime(cvTexture) {}

            while !writerInput.isReadyForMoreMediaData {
                if isCancelled { throw DepthConversionError.cancelled }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: stat.pts) else {
                throw DepthConversionError.encodingFailed(writer?.error?.localizedDescription ?? "append failed")
            }
        }

        // MARK: frame loop

        while true {
            if isCancelled {
                reader.cancelReading()
                throw DepthConversionError.cancelled
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            try autoreleasepool {
                let frameIndex = stats.count
                guard let (rawTex, keepAlive) = provider.inferRawDepth(from: pixelBuffer) else {
                    // Tolerate isolated inference hiccups by repeating the
                    // previous frame's depth; fail only if the first frame does.
                    guard frameIndex > 0 else { throw DepthConversionError.inferenceFailed }
                    guard let cmd = gpu.commandQueue.makeCommandBuffer(),
                          let blit = cmd.makeBlitCommandEncoder() else {
                        throw DepthConversionError.gpuSetupFailed
                    }
                    blit.copy(from: ring[(frameIndex - 1) % ring.count], to: ring[frameIndex % ring.count])
                    blit.endEncoding()
                    cmd.commit()
                    cmd.waitUntilCompleted()
                    let repeated = stats[frameIndex - 1]
                    stats.append(FrameStat(pts: pts, lo: repeated.lo, hi: repeated.hi, median: repeated.median, cutBefore: false))
                    return
                }

                if frameIndex == 0 {
                    decodedWidth = CVPixelBufferGetWidth(pixelBuffer)
                    decodedHeight = CVPixelBufferGetHeight(pixelBuffer)
                    depthWidth = rawTex.width
                    depthHeight = rawTex.height
                    evenWidth = depthWidth & ~1
                    evenHeight = depthHeight & ~1
                    guard evenWidth > 0, evenHeight > 0 else {
                        throw DepthConversionError.inferenceFailed
                    }
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .r16Float, width: depthWidth, height: depthHeight, mipmapped: false
                    )
                    desc.usage = [.shaderRead, .shaderWrite]
                    desc.storageMode = .private
                    for _ in 0..<(2 * Self.temporalRadius + 1) {
                        guard let tex = gpu.device.makeTexture(descriptor: desc) else {
                            throw DepthConversionError.gpuSetupFailed
                        }
                        ring.append(tex)
                    }
                    scratch = gpu.device.makeTexture(descriptor: desc)
                    guideTex = gpu.device.makeTexture(descriptor: desc)
                    guard scratch != nil, guideTex != nil else { throw DepthConversionError.gpuSetupFailed }
                    // Guide kernel maps depth UV back into video UV (inverse of
                    // the warp's letterbox transform).
                    let uv = CoreMLDepthProvider.letterboxUVTransform(
                        videoWidth: decodedWidth, videoHeight: decodedHeight,
                        depthWidth: depthWidth, depthHeight: depthHeight
                    )
                    guideParams = DepthGuideParams(uvScale: uv.scale, uvOffset: uv.offset)
                    (writer, writerInput, adaptor) = try makeWriter(
                        directory: directory, width: evenWidth, height: evenHeight, firstPTS: pts
                    )
                } else if rawTex.width != depthWidth || rawTex.height != depthHeight {
                    throw DepthConversionError.encodingFailed("Depth dimensions changed mid-video")
                }

                // Robust per-frame stats + cut detection.
                let (rawLo, rawHi) = try rawMinMax(of: rawTex)
                let bins = try histogram(of: rawTex, lo: rawLo, hi: rawHi)
                let total = bins.reduce(0) { $0 + Int($1) }
                let p02 = percentile(bins, total: total, q: Self.rangeLoPercentile, lo: rawLo, hi: rawHi)
                let p50 = percentile(bins, total: total, q: 0.5, lo: rawLo, hi: rawHi)
                var p98 = percentile(bins, total: total, q: Self.rangeHiPercentile, lo: rawLo, hi: rawHi)
                if p98 - p02 < 1e-6 { p98 = p02 + 1 } // flat frame — keep the mapping finite

                let shape: [Float] = total > 0 ? bins.map { Float($0) / Float(total) } : Array(repeating: 0, count: 256)
                var cutBefore = false
                if let prev = prevShape, let prevStat = stats.last {
                    let shapeDist = 0.5 * zip(shape, prev).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }
                    let prevSpan = max(prevStat.hi - prevStat.lo, 1e-6)
                    let ratio = (p98 - p02) / prevSpan
                    let loJump = abs(p02 - prevStat.lo) / prevSpan
                    cutBefore = shapeDist > Self.cutShapeDistance
                        || !Self.cutRangeRatioBounds.contains(ratio)
                        || loJump > Self.cutRangeLoJump
                }
                prevShape = shape

                try refine(rawTex: rawTex, videoFrame: pixelBuffer, into: ring[frameIndex % ring.count])
                withExtendedLifetime(keepAlive) {}

                stats.append(FrameStat(pts: pts, lo: p02, hi: p98, median: p50, cutBefore: cutBefore))
            }

            // Emit every frame whose full ±2 window is now available.
            while nextEmit <= stats.count - 1 - Self.temporalRadius {
                try emit(center: nextEmit, lastAvailable: stats.count - 1)
                nextEmit += 1
            }

            if stats.count % 10 == 0 {
                progress(min(0.98 * Double(stats.count) / Double(totalFrames), 0.98))
            }
        }

        if reader.status == .failed {
            throw DepthConversionError.readerInitFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
        guard !stats.isEmpty, let writer, let writerInput else {
            throw DepthConversionError.encodingFailed("No frames decoded")
        }

        // Flush the tail (truncated windows), then finish the file.
        while nextEmit < stats.count {
            try emit(center: nextEmit, lastAvailable: stats.count - 1)
            nextEmit += 1
        }
        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw DepthConversionError.encodingFailed(writer.error?.localizedDescription ?? "Writer failed")
        }

        // Post-pass: lookahead-smoothed display mapping + median, then metadata.
        let meta = buildMeta(
            plan: plan, provider: provider, stats: stats,
            decodedWidth: decodedWidth, decodedHeight: decodedHeight,
            depthWidth: depthWidth, depthHeight: depthHeight
        )
        do {
            try DepthCacheStore.writeMeta(meta, to: directory)
        } catch {
            throw DepthConversionError.encodingFailed("Metadata write failed: \(error.localizedDescription)")
        }
        progress(1.0)
        AppLogger.videoCache.info("Depth conversion complete: \(stats.count, privacy: .public) frames for \(plan.request.videoIdentity, privacy: .private)")
        return Output(directory: directory, meta: meta)
    }

    // MARK: Writer

    private func makeWriter(
        directory: URL, width: Int, height: Int, firstPTS: CMTime
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let outputURL = directory.appendingPathComponent(DepthCacheStore.depthVideoFilename)
        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw DepthConversionError.writerInitFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.depthVideoBitrate
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        guard writer.canAdd(input) else {
            throw DepthConversionError.writerInitFailed("Cannot add writer input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw DepthConversionError.writerInitFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: firstPTS)
        return (writer, input, adaptor)
    }

    // MARK: Post-pass

    /// Turn per-frame raw stats into the final display mapping: within each
    /// cut-delimited segment, the display range is a centered moving average of
    /// the per-frame robust ranges (lookahead smoothing — no pumping, no lag);
    /// across cuts it snaps. Each frame's stored-luma → display-depth affine
    /// (scale/bias) bakes both its encode range and the display range.
    private func buildMeta(
        plan: Plan,
        provider: CoreMLDepthProvider,
        stats: [FrameStat],
        decodedWidth: Int, decodedHeight: Int,
        depthWidth: Int, depthHeight: Int
    ) -> DepthCacheStore.Meta {
        let n = stats.count
        var segmentStarts = [0]
        for i in 1..<max(n, 1) where stats[i].cutBefore {
            segmentStarts.append(i)
        }
        segmentStarts.append(n)

        var displayScale = [Float](repeating: 1, count: n)
        var displayBias = [Float](repeating: 0, count: n)
        var displayMedian = [Float](repeating: 0.5, count: n)

        for s in 0..<(segmentStarts.count - 1) {
            let start = segmentStarts[s]
            let end = segmentStarts[s + 1]
            guard start < end else { continue }

            var rawMedianNorm = [Float](repeating: 0.5, count: end - start)
            for i in start..<end {
                let w0 = max(start, i - Self.rangeSmoothingRadius)
                let w1 = min(end - 1, i + Self.rangeSmoothingRadius)
                var sumLo: Float = 0
                var sumHi: Float = 0
                for j in w0...w1 {
                    sumLo += stats[j].lo
                    sumHi += stats[j].hi
                }
                let count = Float(w1 - w0 + 1)
                let dispLo = sumLo / count
                let span = max(sumHi / count - dispLo, 1e-5)
                displayScale[i] = (stats[i].hi - stats[i].lo) / span
                displayBias[i] = (stats[i].lo - dispLo) / span
                rawMedianNorm[i - start] = min(max((stats[i].median - dispLo) / span, 0), 1)
            }
            // Smooth the median over the same window so auto-convergence drifts
            // rather than tracking per-frame jitter.
            for i in start..<end {
                let w0 = max(start, i - Self.rangeSmoothingRadius)
                let w1 = min(end - 1, i + Self.rangeSmoothingRadius)
                var sum: Float = 0
                for j in w0...w1 { sum += rawMedianNorm[j - start] }
                displayMedian[i] = sum / Float(w1 - w0 + 1)
            }
        }

        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: decodedWidth, videoHeight: decodedHeight,
            depthWidth: depthWidth, depthHeight: depthHeight
        )
        return DepthCacheStore.Meta(
            version: DepthCacheStore.pipelineVersion,
            videoIdentity: plan.request.videoIdentity,
            modelName: provider.modelName,
            title: plan.request.title,
            sourceWidth: decodedWidth,
            sourceHeight: decodedHeight,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            uvScaleX: uv.scale.x,
            uvScaleY: uv.scale.y,
            uvOffsetX: uv.offset.x,
            uvOffsetY: uv.offset.y,
            frameCount: n,
            duration: plan.duration.seconds,
            completed: true,
            createdAt: Date(),
            framePTS: stats.map { $0.pts.seconds },
            displayScale: displayScale,
            displayBias: displayBias,
            displayMedian: displayMedian
        )
    }
}
