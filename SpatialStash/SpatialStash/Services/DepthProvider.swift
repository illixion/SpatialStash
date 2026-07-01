/*
 Spatial Stash - Monocular Depth Provider

 Runs a Core ML monocular-depth model (Depth Anything V2) on decoded video
 frames and exposes the latest depth as a single-channel `MTLTexture` for the
 fake-3D warp (videoPseudo3DEyeFragmentShader samples it when `useDepth` is set).

 Design:
 - Inference runs on its own background queue, off the frame pump and off main.
 - It self-throttles: `submit` is a no-op while an inference is in flight, so
   depth is produced as fast as the ANE allows (depth changes slowly, so the
   warp reusing a slightly stale map between updates is fine).
 - The depth result is copied into a private texture the provider owns, so the
   value the warp reads is stable even as the next inference overwrites Vision's
   output buffer.

 The model is loaded by name from the managed store (Application Support, via
 DepthModelStore) — any Depth Anything V2 variant, since the I/O is identical
 across sizes. Models get there via the in-app download (DepthModelManager) or by
 being dropped into Documents and imported on launch. If no model is present,
 `init?` returns nil and the warp falls back to the heuristic depth, so the app
 still builds and runs without the (large) model asset.
 */

import CoreML
import CoreVideo
import Metal
import os
import Vision

protocol DepthProvider: AnyObject {
    /// Synchronously infer + stabilize depth for this exact frame and return the
    /// matched depth map. Called on the pump queue so the frame isn't shown until
    /// its depth is ready — no lag/ghosting from reusing a stale map. Under slow
    /// inference the pump simply renders fewer frames rather than mismatching.
    func depth(for pixelBuffer: CVPixelBuffer) -> MTLTexture?
}

/// CPU mirror of the Metal `DepthStabilizeParams` struct (int, 3 floats, uint).
private struct DepthStabilizeParams {
    var blurRadius: Int32
    var blurSigma: Float
    var baseAlpha: Float
    var motionGain: Float
    var hasPrev: UInt32
}

final class CoreMLDepthProvider: DepthProvider, @unchecked Sendable {
    private let request: VNCoreMLRequest
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    // Depth stabilization: a spatial gaussian low-pass band-limits the depth so
    // the coarser warp grid doesn't alias its detail into rippling waves, plus a
    // motion-adaptive temporal EMA that damps frame-to-frame jitter without
    // ghosting on motion. Runs at the model's native depth resolution.
    private let stabilizePipeline: MTLComputePipelineState?
    private let stabilizeEnabled = true
    /// Spatial low-pass radius/sigma (depth texels). Band-limits depth for the
    /// 193-wide warp grid (which samples ~every 2.7 texels of the 518-wide map).
    private let blurRadius: Int32 = 6
    private let blurSigma: Float = 3.0
    /// Temporal: blend toward new map where stable (lower = smoother) and how
    /// fast it trusts the new map as depth changes (avoids ghosting on motion).
    private let emaBaseAlpha: Float = 0.35
    private let emaMotionGain: Float = 4.0
    private var emaTexA: MTLTexture?
    private var emaTexB: MTLTexture?
    private var emaWidth = 0
    private var emaHeight = 0
    private var writeA = true
    private var hasPrevDepth = false

    init?(device: MTLDevice) {
        guard let modelURL = Self.findModelURL(),
              let compiledURL = Self.compiledModelURL(for: modelURL),
              let queue = device.makeCommandQueue() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let mlModel = try? MLModel(contentsOf: compiledURL, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlModel) else { return nil }

        let request = VNCoreMLRequest(model: vnModel)
        // The model fixes its own input size; Vision rescales the frame to it.
        request.imageCropAndScaleOption = .scaleFill

        self.request = request
        self.device = device
        self.commandQueue = queue
        self.stabilizePipeline = Self.makeComputePipeline(device: device, function: "depthStabilize")
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        AppLogger.videoWindow.info("CoreMLDepthProvider loaded model: \(modelURL.lastPathComponent, privacy: .public), stabilize=\(self.stabilizePipeline != nil)")
    }

    private static func makeComputePipeline(device: MTLDevice, function: String) -> MTLComputePipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: function) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }

    /// Locate a depth model in the managed store first, then Documents (as a
    /// not-yet-imported fallback), then the bundle. Models are kept out of the
    /// app bundle so builds stay fast (no large Core ML compile step). Accepts a
    /// precompiled `.mlmodelc` (loads directly) or an `.mlpackage` (compiled +
    /// cached by `compiledModelURL`).
    private static func findModelURL() -> URL? {
        let dirs = modelSearchDirectories()

        // Honor an explicit preference (Settings → Depth Model) first: look for
        // that base name (any extension) across Documents then the bundle.
        let preferred = UserDefaults.standard.string(forKey: "preferredDepthModelName") ?? ""
        if !preferred.isEmpty {
            let fm = FileManager.default
            for dir in dirs {
                for ext in ["mlmodelc", "mlpackage"] {
                    let url = dir.appendingPathComponent(preferred).appendingPathExtension(ext)
                    if fm.fileExists(atPath: url.path) { return url }
                }
            }
        }

        for dir in dirs {
            if let url = modelURL(in: dir) { return url }
        }
        return nil
    }

    /// Managed store (checked first), then Documents as a fallback for a model
    /// that hasn't been imported yet, then the app bundle.
    private static func modelSearchDirectories() -> [URL] {
        var dirs: [URL] = [DepthModelStore.modelsDirectory]
        if let docs = DepthModelStore.documentsInbox {
            dirs.append(docs)
        }
        dirs.append(Bundle.main.bundleURL)
        return dirs
    }

    /// Find a depth model in `directory`, preferring compiled `.mlmodelc` over
    /// `.mlpackage`, and known Depth Anything names over a generic "depth" match.
    private static func modelURL(in directory: URL) -> URL? {
        let fm = FileManager.default
        let names = [
            "DepthAnythingV2Base", "DepthAnythingV2BaseF16",
            "DepthAnythingV2SmallF16", "DepthAnythingV2Small", "DepthAnythingV2"
        ]
        for ext in ["mlmodelc", "mlpackage"] {
            for name in names {
                let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        if let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            return urls.first {
                ["mlmodelc", "mlpackage"].contains($0.pathExtension) &&
                $0.lastPathComponent.localizedCaseInsensitiveContains("depth")
            }
        }
        return nil
    }

    /// Returns a loadable compiled-model URL. `.mlmodelc` is used directly;
    /// `.mlpackage` is compiled and cached under Application Support (recompiled
    /// only when the source is newer), so dropping an `.mlpackage` into Documents
    /// to swap models works without a rebuild.
    private static func compiledModelURL(for url: URL) -> URL? {
        if url.pathExtension == "mlmodelc" { return url }

        let fm = FileManager.default
        let cacheDir = DepthModelStore.compiledCacheDirectory
        let cached = cacheDir
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mlmodelc")

        if fm.fileExists(atPath: cached.path),
           let cachedDate = (try? fm.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date,
           let sourceDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           cachedDate >= sourceDate {
            return cached
        }

        guard let compiled = try? MLModel.compileModel(at: url) else { return nil }
        try? fm.removeItem(at: cached)
        if (try? fm.copyItem(at: compiled, to: cached)) != nil {
            return cached
        }
        return compiled
    }

    func depth(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])

        let raw: MTLTexture?
        if let obs = request.results?.first as? VNPixelBufferObservation {
            raw = stableTexture(from: obs.pixelBuffer)
        } else if let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let array = obs.featureValue.multiArrayValue {
            raw = makeTexture(from: array)
        } else {
            raw = nil
        }
        guard let raw else { return nil }

        // Band-limit + temporally smooth to remove ripple (spatial aliasing) and
        // wobble (temporal jitter). Falls back to the raw map if unavailable.
        return stabilizeEnabled ? (stabilize(rawDepth: raw) ?? raw) : raw
    }

    // MARK: - Depth stabilization

    /// Spatially band-limit + motion-adaptively temporally smooth `rawDepth`
    /// (same resolution). Returns a private r16Float texture from the ping-pong
    /// pair; safe to publish because the next call writes the *other* buffer,
    /// never the one the warp may currently be reading.
    private func stabilize(rawDepth: MTLTexture) -> MTLTexture? {
        guard let stabilizePipeline else { return nil }
        let w = rawDepth.width, h = rawDepth.height
        guard w > 0, h > 0,
              ensureEMATextures(width: w, height: h),
              let prev = writeA ? emaTexB : emaTexA,
              let next = writeA ? emaTexA : emaTexB,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        var params = DepthStabilizeParams(
            blurRadius: blurRadius,
            blurSigma: blurSigma,
            baseAlpha: emaBaseAlpha,
            motionGain: emaMotionGain,
            hasPrev: hasPrevDepth ? 1 : 0
        )
        enc.setComputePipelineState(stabilizePipeline)
        enc.setTexture(rawDepth, index: 0)
        enc.setTexture(prev, index: 1)
        enc.setTexture(next, index: 2)
        enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        writeA.toggle()
        hasPrevDepth = true
        return next
    }

    private func ensureEMATextures(width: Int, height: Int) -> Bool {
        if emaTexA != nil, emaTexB != nil, emaWidth == width, emaHeight == height {
            return true
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc) else { return false }
        emaTexA = a
        emaTexB = b
        emaWidth = width
        emaHeight = height
        writeA = true
        hasPrevDepth = false
        return true
    }

    // MARK: - Output → texture

    /// Image output: import via the texture cache, then blit into a private
    /// texture the provider owns so it stays valid after Vision recycles its buffer.
    private func stableTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent8:
            pixelFormat = .r8Unorm
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32:
            pixelFormat = .r32Float
        default: // OneComponent16Half / DepthFloat16 and friends
            pixelFormat = .r16Float
        }

        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, pixelFormat, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture, let transient = CVMetalTextureGetTexture(cvTexture) else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let dest = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: transient, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: dest, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return dest
    }

    /// MLMultiArray output: normalize to 0-1 and upload to an r16Float texture.
    /// Assumes the last two dimensions are height × width.
    private func makeTexture(from array: MLMultiArray) -> MTLTexture? {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 0, height > 0 else { return nil }

        let count = width * height
        var values = [Float](repeating: 0, count: count)
        let base = 0 // first slice of any leading (batch/channel) dimensions
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<count { values[i] = ptr[base + i] }
        case .float16:
            let ptr = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<count { values[i] = Self.float16ToFloat(ptr[base + i]) }
        case .double:
            let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<count { values[i] = Float(ptr[base + i]) }
        default:
            return nil
        }

        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        for v in values { minV = min(minV, v); maxV = max(maxV, v) }
        let range = max(maxV - minV, 1e-5)
        var halfValues = [UInt16](repeating: 0, count: count)
        for i in 0..<count { halfValues[i] = Self.floatToFloat16((values[i] - minV) / range) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        halfValues.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 2)
        }
        return texture
    }

    // Minimal IEEE-754 half<->float helpers (avoids a Float16 platform dependency).
    private static func float16ToFloat(_ h: UInt16) -> Float {
        Float(Float16(bitPattern: h))
    }
    private static func floatToFloat16(_ f: Float) -> UInt16 {
        Float16(f).bitPattern
    }
}
