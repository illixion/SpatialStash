/*
 Spatial Stash - Pseudo 3D Video Player View

 Real-time "fake 3D" video in a normal (Shared Space) window — no immersive
 space, no MV-HEVC pre-compute. Architecture:

   AVPlayer (audio + master clock + transport + scrubbing + A-B loop)
        │  decoded mono frames via AVPlayerItemVideoOutput
        ▼
   per tick: warp the mono frame into LEFT + RIGHT eye buffers
        │  (videoPseudo3DEyeFragmentShader, cheap heuristic depth — see
        │   Pseudo3DSettings; depth source is isolated for a future Core ML swap)
        ▼
   tagged CMReadySampleBuffer (.leftEye / .rightEye)
        │
        ▼
   AVSampleBufferVideoRenderer ─▶ VideoPlayerComponent(.stereo) in a RealityView

 The renderer's synchronizer free-runs at rate 1 and we enqueue the latest
 decoded frame each tick tagged "now", so AVPlayer remains the single clock that
 governs audio, pause, and seek; the sample-buffer renderer is purely a
 stereoscopic presentation surface. This reuses the existing VideoWindowModel
 command/loop/visual-adjustment plumbing unchanged.

 visionOS 26 APIs: CMReadySampleBuffer / CMTaggedDynamicBuffer / CVReadOnlyPixelBuffer.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import RealityKit
import SwiftUI

/// CPU mirror of the Metal `VideoStereoUniforms` struct (7 contiguous floats).
private struct VideoStereoUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var depthStrength: Float
    var convergence: Float
    var eyeSign: Float
    var mirror: Float
}

struct Pseudo3DVideoPlayerView: View {
    let videoURL: URL
    var isRoomActive: Bool = true
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var settings: Pseudo3DSettings = .default
    var isFlipped: Bool = false
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    var onPlaybackError: (() -> Void)? = nil

    @State private var engine = Pseudo3DStereoEngine()

    var body: some View {
        RealityView { content in
            engine.configure(
                visualAdjustments: visualAdjustments,
                settings: settings,
                isFlipped: isFlipped
            )
            engine.onVideoSizeKnown = onVideoSizeKnown
            engine.onPlaybackError = onPlaybackError
            content.add(engine.makeVideoEntity())
            engine.load(url: videoURL, roomActive: isRoomActive)
        }
        .onChange(of: videoURL) { _, newURL in
            engine.load(url: newURL, roomActive: isRoomActive)
        }
        .onAppear {
            engine.bindCommands(loopController: loopController, playbackModel: playbackModel)
            engine.configure(visualAdjustments: visualAdjustments, settings: settings, isFlipped: isFlipped)
            engine.setRoomActive(isRoomActive)
        }
        .onChange(of: visualAdjustments) { _, new in
            engine.configure(visualAdjustments: new, settings: settings, isFlipped: isFlipped)
        }
        .onChange(of: settings) { _, new in
            engine.configure(visualAdjustments: visualAdjustments, settings: new, isFlipped: isFlipped)
        }
        .onChange(of: isFlipped) { _, new in
            engine.configure(visualAdjustments: visualAdjustments, settings: settings, isFlipped: new)
        }
        .onChange(of: isRoomActive) { _, active in
            engine.setRoomActive(active)
        }
        .onDisappear {
            engine.cleanup()
        }
    }
}

// MARK: - Engine

@MainActor
@Observable
final class Pseudo3DStereoEngine {
    // Presentation
    private let videoRenderer = AVSampleBufferVideoRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var didStartSynchronizer = false

    // Source / clock
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var loadedURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var isRoomActive = true

    // GPU
    private var textureCache: CVMetalTextureCache?
    private var eyePool: CVPixelBufferPool?
    private var eyePoolWidth = 0
    private var eyePoolHeight = 0

    // Render loop
    private var renderLoopTask: Task<Void, Never>?

    // Config
    private var visualAdjustments = VisualAdjustments()
    private var settings = Pseudo3DSettings.default
    private var isFlipped = false

    // A-B loop
    private var loopA: Double?
    private var loopB: Double?

    // Callbacks
    @ObservationIgnored var onVideoSizeKnown: ((CGSize) -> Void)?
    @ObservationIgnored var onPlaybackError: (() -> Void)?
    @ObservationIgnored private var onPlaybackUpdate: ((NativeMetalVideoPlayerView.Coordinator.PlaybackState) -> Void)?
    private var lastReportedSize: CGSize?

    init() {
        synchronizer.addRenderer(videoRenderer)
        if let device = MetalImageRenderer.shared?.device {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        }
    }

    // MARK: Entity

    func makeVideoEntity() -> Entity {
        let entity = Entity()
        var component = VideoPlayerComponent(videoRenderer: videoRenderer)
        component.desiredViewingMode = VideoPlaybackController.ViewingMode.stereo
        component.isPassthroughTintingEnabled = false
        entity.components.set(component)
        return entity
    }

    // MARK: Config

    func configure(visualAdjustments: VisualAdjustments, settings: Pseudo3DSettings, isFlipped: Bool) {
        self.visualAdjustments = visualAdjustments
        self.settings = settings
        self.isFlipped = isFlipped
    }

    func bindCommands(loopController: VideoLoopController?, playbackModel: VideoWindowModel?) {
        if let loopController {
            loopController.queryCurrentTime = { [weak self] in self?.currentTime }
            loopController.setLoopBounds = { [weak self] a, b in self?.setLoopBounds(a: a, b: b) }
        }
        if let playbackModel {
            playbackModel.playCommand = { [weak self] in self?.play() }
            playbackModel.pauseCommand = { [weak self] in self?.pause() }
            playbackModel.seekCommand = { [weak self] t in self?.seek(to: t) }
            playbackModel.setMutedCommand = { [weak self] m in self?.setMuted(m) }
            onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered
                )
            }
        }
    }

    // MARK: Load / transport

    var currentTime: Double { player?.currentTime().seconds ?? 0 }

    func load(url: URL, roomActive: Bool) {
        guard loadedURL != url else { return }
        cleanupPlayer()
        loadedURL = url
        isRoomActive = roomActive

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true

        self.player = player
        self.playerItem = item
        self.videoOutput = output

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.seek(to: 0)
                if self?.isRoomActive == true { self?.play() }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlaybackError?() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTimeUpdate(time.seconds) }
        }

        startRenderLoop()
        if !didStartSynchronizer {
            didStartSynchronizer = true
            synchronizer.setRate(1, time: .zero)
        }
        if isRoomActive { play() }
    }

    func play() { isRoomActive = true; player?.play() }
    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
        reportPlaybackState()
    }

    func setLoopBounds(a: Double?, b: Double?) { loopA = a; loopB = b }

    func setRoomActive(_ active: Bool) {
        guard isRoomActive != active else { return }
        isRoomActive = active
        if active { play() } else { pause() }
    }

    private func handleTimeUpdate(_ seconds: Double) {
        if let loopA, let loopB, seconds >= loopB - (1.0 / 60.0) { seek(to: loopA) }
        reportPlaybackState(currentTime: seconds)
    }

    private func reportPlaybackState(currentTime: Double? = nil) {
        guard let player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let ranges = player.currentItem?.loadedTimeRanges ?? []
        let buffered = ranges
            .map(\.timeRangeValue)
            .map { $0.start.seconds + $0.duration.seconds }
            .filter { $0.isFinite }
            .max() ?? 0
        onPlaybackUpdate?(
            .init(
                currentTime: currentTime ?? player.currentTime().seconds,
                duration: duration.isFinite ? duration : 0,
                paused: player.timeControlStatus != .playing,
                muted: player.isMuted,
                buffered: buffered
            )
        )
    }

    // MARK: Render loop

    private func startRenderLoop() {
        renderLoopTask?.cancel()
        renderLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.renderTick()
                // ~90 Hz pump; the warp is cheap and we only enqueue when a new
                // decoded frame is available and the renderer wants more data.
                try? await Task.sleep(for: .milliseconds(11))
            }
        }
    }

    private func renderTick() {
        guard videoRenderer.isReadyForMoreMediaData,
              let output = videoOutput,
              let textureCache,
              let renderer = MetalImageRenderer.shared else { return }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let src = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        reportSizeIfNeeded(src)

        guard let (left, right) = makeEyePair(from: src, renderer: renderer, cache: textureCache) else { return }
        enqueueStereo(left: left, right: right, pts: synchronizer.currentTime())
    }

    private func makeEyePair(
        from src: CVPixelBuffer,
        renderer: MetalImageRenderer,
        cache: CVMetalTextureCache
    ) -> (CVPixelBuffer, CVPixelBuffer)? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width > 0, height > 0,
              let pool = ensureEyePool(width: width, height: height),
              let srcTexture = makeTexture(from: src, cache: cache) else { return nil }

        var leftBuf: CVPixelBuffer?
        var rightBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &leftBuf) == kCVReturnSuccess,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rightBuf) == kCVReturnSuccess,
              let left = leftBuf, let right = rightBuf,
              let leftTex = makeTexture(from: left, cache: cache),
              let rightTex = makeTexture(from: right, cache: cache),
              let cmdBuf = renderer.commandQueue.makeCommandBuffer() else { return nil }

        encodeEye(into: leftTex, source: srcTexture, eyeSign: 1.0, renderer: renderer, commandBuffer: cmdBuf)
        encodeEye(into: rightTex, source: srcTexture, eyeSign: -1.0, renderer: renderer, commandBuffer: cmdBuf)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return (left, right)
    }

    private func encodeEye(
        into dest: MTLTexture,
        source: MTLTexture,
        eyeSign: Float,
        renderer: MetalImageRenderer,
        commandBuffer: MTLCommandBuffer
    ) {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = dest
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        encoder.setRenderPipelineState(renderer.pseudo3DEyePipelineState)
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = VideoStereoUniforms(
            brightness: Float(visualAdjustments.brightness),
            contrast: Float(visualAdjustments.contrast),
            saturation: Float(visualAdjustments.saturation),
            depthStrength: Float(settings.depthStrength),
            convergence: Float(settings.convergence),
            eyeSign: eyeSign,
            mirror: isFlipped ? 1.0 : 0.0
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoStereoUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func enqueueStereo(left: CVPixelBuffer, right: CVPixelBuffer, pts: CMTime) {
        let presentation = pts.isValid ? pts : .zero
        let leftTags: [CMTag] = [.videoLayerID(0), .stereoView(.leftEye), .mediaType(.video)]
        let rightTags: [CMTag] = [.videoLayerID(1), .stereoView(.rightEye), .mediaType(.video)]
        // CVReadOnlyPixelBuffer(unsafeBuffer:) takes a `sending` CVPixelBuffer:
        // ownership transfers here. The buffers were freshly allocated from the
        // pool this tick and the GPU warp has completed (waitUntilCompleted), so
        // they are uniquely owned and untouched after this point — but creating
        // MTLTextures from them taints their region for the sending check, so we
        // assert the transfer explicitly.
        nonisolated(unsafe) let leftBuf = left
        nonisolated(unsafe) let rightBuf = right
        let tagged: [CMTaggedDynamicBuffer] = [
            CMTaggedDynamicBuffer(tags: leftTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(unsafeBuffer: leftBuf))),
            CMTaggedDynamicBuffer(tags: rightTags, content: .pixelBuffer(CVReadOnlyPixelBuffer(unsafeBuffer: rightBuf)))
        ]
        // formatDescription is optional (defaults to nil); the system derives a
        // tagged-buffer-group format description from the buffers themselves.
        let sample = CMReadySampleBuffer(
            taggedBuffers: tagged,
            presentationTimeStamp: presentation,
            duration: CMTime(value: 1, timescale: 90)
        )
        sample.withUnsafeSampleBuffer { cmSampleBuffer in
            videoRenderer.enqueue(cmSampleBuffer)
        }
    }

    // MARK: GPU helpers

    private func ensureEyePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let eyePool, eyePoolWidth == width, eyePoolHeight == height { return eyePool }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        eyePool = pool
        eyePoolWidth = width
        eyePoolHeight = height
        return pool
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func reportSizeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard size.width > 0, size.height > 0, lastReportedSize != size else { return }
        lastReportedSize = size
        onVideoSizeKnown?(size)
    }

    // MARK: Cleanup

    func cleanup() {
        renderLoopTask?.cancel()
        renderLoopTask = nil
        cleanupPlayer()
        videoRenderer.flush()
        videoRenderer.stopRequestingMediaData()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        eyePool = nil
        onVideoSizeKnown = nil
        onPlaybackError = nil
        onPlaybackUpdate = nil
    }

    private func cleanupPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player?.pause()
        if let videoOutput { playerItem?.remove(videoOutput) }
        timeObserver = nil
        endObserver = nil
        failureObserver = nil
        player = nil
        playerItem = nil
        videoOutput = nil
        loadedURL = nil
        lastReportedSize = nil
        loopA = nil
        loopB = nil
    }
}
