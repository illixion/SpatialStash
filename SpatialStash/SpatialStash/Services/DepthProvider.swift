/*
 Spatial Stash - Monocular Depth Provider

 Runs a Core ML monocular-depth model (Depth Anything V2) on decoded video
 frames and exposes the latest depth as a single-channel `MTLTexture` for the
 fake-3D warp (videoPseudo3DEyeFragmentShader samples it when `useDepth` is set).

 Design:
 - `depth(for:)` is fully synchronous and runs on the pump queue (never main):
   the frame isn't shown until its depth is ready, so image and depth always
   match exactly — slow inference yields fewer frames, never ghosting.
 - The returned texture is provider-owned (a stabilize ping-pong buffer, or a
   blitted copy when stabilization is unavailable), so it stays valid while the
   warp reads it even as the next inference overwrites Vision's output buffer.

 The model is loaded by name from the managed store (Application Support, via
 DepthModelStore) — any Depth Anything V2 variant, since the I/O is identical
 across sizes. Models get there via the in-app download (DepthModelManager) or by
 being dropped into Documents and imported on launch. If no model is present,
 `init?` returns nil and the warp falls back to the heuristic depth, so the app
 still builds and runs without the (large) model asset.
 */

import CoreMedia
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

/// Everything the warp needs to use a depth map for one frame.
struct PumpFrameDepth {
    let texture: MTLTexture
    /// Letterbox UV transform (frame UV → depth content region).
    let uvScale: SIMD2<Float>
    let uvOffset: SIMD2<Float>
    /// Stored sample → display depth affine (identity for realtime inference;
    /// cached depth bakes its per-frame encode + display ranges here).
    let valueScale: Float
    let valueBias: Float
    /// Display-space median depth (auto-convergence); nil when unknown.
    let median: Float?
}

/// StereoPump's per-frame depth supplier. Implementations are called only on
/// the pump queue (including `invalidate`, from the stop-drain block).
protocol PumpDepthSource: AnyObject {
    /// Depth for the frame with presentation time `itemTime`, or nil when none
    /// is available right now (inference failure / cache seek gap).
    func frameDepth(itemTime: CMTime, frame: CVPixelBuffer) -> PumpFrameDepth?
    /// True when missing depth should render FLAT (cached mode: a seek gap must
    /// not fall back to the different-looking heuristic warp); false to use the
    /// heuristic (realtime mode: an isolated inference hiccup).
    var flattensWhenUnavailable: Bool { get }
    /// Release decode/GPU resources; the pump is shutting down.
    func invalidate()
}

/// Realtime source: synchronous same-frame Core ML inference (the 30fps path).
final class RealtimeDepthSource: PumpDepthSource, @unchecked Sendable {
    private let provider: CoreMLDepthProvider

    init?(device: MTLDevice) {
        guard let provider = CoreMLDepthProvider(device: device) else { return nil }
        self.provider = provider
    }

    let flattensWhenUnavailable = false

    func frameDepth(itemTime: CMTime, frame: CVPixelBuffer) -> PumpFrameDepth? {
        guard let texture = provider.depth(for: frame) else { return nil }
        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: CVPixelBufferGetWidth(frame), videoHeight: CVPixelBufferGetHeight(frame),
            depthWidth: texture.width, depthHeight: texture.height
        )
        return PumpFrameDepth(
            texture: texture, uvScale: uv.scale, uvOffset: uv.offset,
            valueScale: 1, valueBias: 0, median: nil
        )
    }

    func invalidate() {}
}

/// CPU mirror of the Metal `DepthStabilizeParams` struct (int, 3 floats, uint,
/// float). Internal (not private): the offline `DepthConverter` reuses the
/// blur/bilateral kernels.
struct DepthStabilizeParams {
    var blurRadius: Int32
    var blurSigma: Float
    var baseAlpha: Float
    var motionGain: Float
    var hasPrev: UInt32
    /// Joint-bilateral luma sigma; unused by the plain gaussian kernels.
    var sigmaLuma: Float = 0
}

final class CoreMLDepthProvider: DepthProvider, @unchecked Sendable {
    private let request: VNCoreMLRequest
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    /// Base name of the loaded model (no extension) — identifies which model
    /// produced a depth cache entry.
    let modelName: String

    // Depth stabilization: a spatial gaussian low-pass band-limits the depth so
    // the coarser warp grid doesn't alias its detail into rippling waves, plus a
    // motion-adaptive temporal EMA that damps frame-to-frame jitter without
    // ghosting on motion. Runs at the model's native depth resolution as two
    // separable 1D passes (H → scratch → V+EMA) in one command buffer.
    private let blurHPipeline: MTLComputePipelineState?
    private let blurVEMAPipeline: MTLComputePipelineState?
    private var stabilizeAvailable: Bool { blurHPipeline != nil && blurVEMAPipeline != nil }
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
    /// Intermediate target for the horizontal blur pass.
    private var blurScratchTex: MTLTexture?
    private var emaWidth = 0
    private var emaHeight = 0
    private var writeA = true
    private var hasPrevDepth = false

    private let signposter = AppLogger.pseudo3DSignposter

    init?(device: MTLDevice) {
        guard let modelURL = Self.findModelURL(),
              let compiledURL = Self.compiledModelURL(for: modelURL),
              let queue = device.makeCommandQueue() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let mlModel = try? MLModel(contentsOf: compiledURL, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlModel) else { return nil }

        let request = VNCoreMLRequest(model: vnModel)
        // The model fixes its own (square) input size; Vision letterboxes the
        // frame into it, preserving aspect. `.scaleFill` stretched non-square
        // video, distorting depth — the warp remaps UVs into the content region
        // via VideoStereoUniforms.depthUVScale/Offset (see depthUVTransform).
        request.imageCropAndScaleOption = .scaleFit

        self.request = request
        self.device = device
        self.commandQueue = queue
        self.modelName = modelURL.deletingPathExtension().lastPathComponent
        self.blurHPipeline = Self.makeComputePipeline(device: device, function: "depthBlurH")
        self.blurVEMAPipeline = Self.makeComputePipeline(device: device, function: "depthBlurVEMA")
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        AppLogger.videoWindow.info("CoreMLDepthProvider loaded model: \(modelURL.lastPathComponent, privacy: .public), stabilize=\(self.stabilizeAvailable)")
    }

    private static func makeComputePipeline(device: MTLDevice, function: String) -> MTLComputePipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: function) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }

    /// Resolve the depth model to load. Fake-3D requires a real model (there is
    /// no heuristic fallback): use the explicit preference if it's present, else
    /// the first installed model, else nil (no model → the engine declines to run
    /// fake-3D rather than showing a heuristic warp). `.mlmodelc` loads directly;
    /// `.mlpackage` is compiled + cached by `compiledModelURL`.
    private static func findModelURL() -> URL? {
        let preferred = UserDefaults.standard.string(forKey: "preferredDepthModelName") ?? ""
        if !preferred.isEmpty {
            let fm = FileManager.default
            for dir in modelSearchDirectories() {
                for ext in ["mlmodelc", "mlpackage"] {
                    let url = dir.appendingPathComponent(preferred).appendingPathExtension(ext)
                    if fm.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return DepthModelStore.installedModelURLs().first
    }

    /// Whether any depth model is available to load. Fake-3D needs one — the
    /// engine uses this to decline (fall back to 2D) rather than warp heuristically.
    static func hasAvailableModel() -> Bool { findModelURL() != nil }

    /// Base name of the model `init?` would load, without loading it. Used to
    /// key depth cache lookups before spinning up a provider.
    static func resolvedModelName() -> String? {
        findModelURL()?.deletingPathExtension().lastPathComponent
    }

    /// Where `.scaleFit` anchors the frame inside the model's input. Vision
    /// doesn't document the padding placement; 0.5 = centered. If on-device
    /// parallax reads vertically offset on non-square video, flip y to 0 (top)
    /// or 1 (bottom).
    private static let letterboxAnchor = SIMD2<Float>(0.5, 0.5)

    /// UV transform mapping frame UV → the content region of a `.scaleFit`
    /// letterboxed depth map: sample depth at `uv * scale + offset`. Identity
    /// when the aspects already match. Shared by the realtime warp and the
    /// offline depth converter so cached and live depth agree.
    static func letterboxUVTransform(
        videoWidth: Int, videoHeight: Int, depthWidth: Int, depthHeight: Int
    ) -> (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        guard videoWidth > 0, videoHeight > 0, depthWidth > 0, depthHeight > 0 else {
            return (SIMD2(1, 1), SIMD2(0, 0))
        }
        let vw = Float(videoWidth), vh = Float(videoHeight)
        let dw = Float(depthWidth), dh = Float(depthHeight)
        let s = min(dw / vw, dh / vh)
        let content = SIMD2(vw * s / dw, vh * s / dh)
        return (content, (SIMD2(1, 1) - content) * letterboxAnchor)
    }

    /// The managed store, then the app bundle. Documents is intentionally NOT
    /// searched: it's only a drop-off inbox, drained into the store on launch
    /// (`DepthModelStore.importInboxModels`) and when Settings opens. Keeping the
    /// store authoritative means a model can never load yet be invisible to the
    /// Settings picker / undeletable — a model pushed to Documents loads after
    /// the next launch, once imported into the store.
    private static func modelSearchDirectories() -> [URL] {
        [DepthModelStore.modelsDirectory, Bundle.main.bundleURL]
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

    /// Run the Vision request and return the first observation. One request
    /// instance per provider — callers must not run concurrently (the realtime
    /// pump and the offline converter each own their own provider).
    private func performInference(on pixelBuffer: CVPixelBuffer) -> VNObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    /// Raw model output for one frame: unstabilized and unnormalized (values in
    /// the model's own arbitrary per-frame scale). For the offline converter,
    /// which does its own normalization and temporal smoothing. The texture may
    /// be a transient view — valid only while `keepAlive` is retained.
    func inferRawDepth(from pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, keepAlive: [Any])? {
        let inferState = signposter.beginInterval("depth-inference")
        defer { signposter.endInterval("depth-inference", inferState) }
        switch performInference(on: pixelBuffer) {
        case let obs as VNPixelBufferObservation:
            return transientTexture(from: obs.pixelBuffer)
        case let obs as VNCoreMLFeatureValueObservation:
            guard let array = obs.featureValue.multiArrayValue,
                  let texture = rawTexture(from: array) else { return nil }
            return (texture, [])
        default:
            return nil
        }
    }

    func depth(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let inferState = signposter.beginInterval("depth-inference")

        // When stabilization will run, the raw texture only needs to survive the
        // stabilize pass's synchronous wait (same call stack), so the pixel-buffer
        // path can use a zero-copy texture-cache view with keep-alives instead of
        // an owned blit copy. Without stabilization the raw texture IS the result
        // and outlives this call (the warp reads it later), so it must be copied.
        let raw: MTLTexture?
        var keepAlive: [Any] = []
        switch performInference(on: pixelBuffer) {
        case let obs as VNPixelBufferObservation:
            if stabilizeEnabled, stabilizeAvailable,
               let transient = transientTexture(from: obs.pixelBuffer) {
                raw = transient.texture
                keepAlive = transient.keepAlive
            } else {
                raw = copiedTexture(from: obs.pixelBuffer)
            }
        case let obs as VNCoreMLFeatureValueObservation:
            raw = obs.featureValue.multiArrayValue.flatMap { makeTexture(from: $0) }
        default:
            raw = nil
        }
        signposter.endInterval("depth-inference", inferState)
        guard let raw else { return nil }

        // Band-limit + temporally smooth to remove ripple (spatial aliasing) and
        // wobble (temporal jitter). Falls back to the raw map if unavailable.
        guard stabilizeEnabled else { return raw }
        let stabilizeState = signposter.beginInterval("depth-stabilize")
        defer { signposter.endInterval("depth-stabilize", stabilizeState) }
        let stabilized = stabilize(rawDepth: raw)
        withExtendedLifetime(keepAlive) {}
        // If stabilize failed, only the owned-copy path may be returned raw; a
        // transient view would dangle once Vision recycles its buffer.
        if stabilized == nil, !keepAlive.isEmpty { return nil }
        return stabilized ?? raw
    }

    // MARK: - Depth stabilization

    /// Spatially band-limit + motion-adaptively temporally smooth `rawDepth`
    /// (same resolution). Returns a private r16Float texture from the ping-pong
    /// pair; safe to publish because the next call writes the *other* buffer,
    /// never the one the warp may currently be reading.
    private func stabilize(rawDepth: MTLTexture) -> MTLTexture? {
        guard let blurHPipeline, let blurVEMAPipeline else { return nil }
        let w = rawDepth.width, h = rawDepth.height
        guard w > 0, h > 0,
              ensureEMATextures(width: w, height: h),
              let scratch = blurScratchTex,
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
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1)

        // Separable gaussian: H pass into the scratch, then V pass + EMA. Both
        // textures are hazard-tracked, so Metal orders the two dispatches.
        enc.setComputePipelineState(blurHPipeline)
        enc.setTexture(rawDepth, index: 0)
        enc.setTexture(scratch, index: 1)
        enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)

        enc.setComputePipelineState(blurVEMAPipeline)
        enc.setTexture(scratch, index: 0)
        enc.setTexture(prev, index: 1)
        enc.setTexture(next, index: 2)
        enc.setBytes(&params, length: MemoryLayout<DepthStabilizeParams>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        writeA.toggle()
        hasPrevDepth = true
        return next
    }

    private func ensureEMATextures(width: Int, height: Int) -> Bool {
        if emaTexA != nil, emaTexB != nil, blurScratchTex != nil, emaWidth == width, emaHeight == height {
            return true
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let a = device.makeTexture(descriptor: desc),
              let b = device.makeTexture(descriptor: desc),
              let scratch = device.makeTexture(descriptor: desc) else { return false }
        emaTexA = a
        emaTexB = b
        blurScratchTex = scratch
        emaWidth = width
        emaHeight = height
        writeA = true
        hasPrevDepth = false
        return true
    }

    // MARK: - Output → texture

    private static func depthPixelFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent8:
            return .r8Unorm
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32:
            return .r32Float
        default: // OneComponent16Half / DepthFloat16 and friends
            return .r16Float
        }
    }

    /// Image output, zero-copy: a texture-cache view of Vision's buffer, valid
    /// only while `keepAlive` is retained (until the stabilize pass's synchronous
    /// wait returns, on the same call stack). Never return this texture itself.
    private func transientTexture(from pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, keepAlive: [Any])? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, Self.depthPixelFormat(for: pixelBuffer), width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, [cvTexture, pixelBuffer])
    }

    /// Image output, owned copy: import via the texture cache, then blit into a
    /// private texture the provider owns so it stays valid after Vision recycles
    /// its buffer. Fallback for when stabilization can't run (the raw texture is
    /// then returned to the warp directly and must outlive this call).
    private func copiedTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let (transient, keepAlive) = transientTexture(from: pixelBuffer) else { return nil }
        let width = transient.width
        let height = transient.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: transient.pixelFormat, width: width, height: height, mipmapped: false
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
        withExtendedLifetime(keepAlive) {}
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

    /// MLMultiArray output, raw: upload the model's values verbatim (no min/max
    /// normalization — the offline converter normalizes with its own temporally
    /// smoothed range). float16 → r16Float memcpy; float32/double → r32Float.
    private func rawTexture(from array: MLMultiArray) -> MTLTexture? {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 0, height > 0 else { return nil }

        func makeTexture(_ format: MTLPixelFormat, bytes: UnsafeRawPointer, bytesPerRow: Int) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            desc.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: desc) else { return nil }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: bytesPerRow)
            return texture
        }

        switch array.dataType {
        case .float16:
            return makeTexture(.r16Float, bytes: array.dataPointer, bytesPerRow: width * 2)
        case .float32:
            return makeTexture(.r32Float, bytes: array.dataPointer, bytesPerRow: width * 4)
        case .double:
            let count = width * height
            let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
            var values = [Float](repeating: 0, count: count)
            for i in 0..<count { values[i] = Float(ptr[i]) }
            return values.withUnsafeBytes { bytes in
                makeTexture(.r32Float, bytes: bytes.baseAddress!, bytesPerRow: width * 4)
            }
        default:
            return nil
        }
    }

    // Minimal IEEE-754 half<->float helpers (avoids a Float16 platform dependency).
    private static func float16ToFloat(_ h: UInt16) -> Float {
        Float(Float16(bitPattern: h))
    }
    private static func floatToFloat16(_ f: Float) -> UInt16 {
        Float16(f).bitPattern
    }
}
