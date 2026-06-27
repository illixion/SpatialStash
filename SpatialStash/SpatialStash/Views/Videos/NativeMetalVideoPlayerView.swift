/*
 Spatial Stash - Native Metal Video Player View

 AVFoundation-backed video player that renders decoded frames through Metal.
 Used for formats AVFoundation can decode natively, while WKWebView remains the
 fallback for WebM and other Safari-only formats.
 */

import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI

private struct VideoRCASUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var sharpen: Float
}

private struct VideoAAUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var applyResolve: Float
}

struct NativeMetalVideoPlayerView: UIViewRepresentable {
    let videoURL: URL
    var isRoomActive: Bool = true
    var onVideoSizeKnown: ((CGSize) -> Void)? = nil
    var visualAdjustments: VisualAdjustments = VisualAdjustments()
    var loopController: VideoLoopController? = nil
    var playbackModel: VideoWindowModel? = nil
    var onPlaybackError: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        guard let renderer = MetalImageRenderer.shared else {
            return MTKView()
        }

        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = context.coordinator
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        context.coordinator.renderer = renderer
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.visualAdjustments = visualAdjustments
        coordinator.onVideoSizeKnown = onVideoSizeKnown
        coordinator.onPlaybackError = onPlaybackError

        if let loopController {
            loopController.queryCurrentTime = { [weak coordinator] in
                coordinator?.currentTime
            }
            loopController.setLoopBounds = { [weak coordinator] a, b in
                coordinator?.setLoopBounds(a: a, b: b)
            }
        }

        if let playbackModel {
            playbackModel.playCommand = { [weak coordinator] in
                coordinator?.play()
            }
            playbackModel.pauseCommand = { [weak coordinator] in
                coordinator?.pause()
            }
            playbackModel.seekCommand = { [weak coordinator] time in
                coordinator?.seek(to: time)
            }
            playbackModel.setMutedCommand = { [weak coordinator] muted in
                coordinator?.setMuted(muted)
            }
            coordinator.onPlaybackUpdate = { [weak playbackModel] state in
                playbackModel?.applyPlaybackState(
                    currentTime: state.currentTime,
                    duration: state.duration,
                    paused: state.paused,
                    muted: state.muted,
                    buffered: state.buffered
                )
            }
        }

        if coordinator.loadedURL != videoURL {
            coordinator.load(url: videoURL)
        }

        coordinator.setRoomActive(isRoomActive)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        struct PlaybackState {
            let currentTime: Double
            let duration: Double
            let paused: Bool
            let muted: Bool
            let buffered: Double
        }

        weak var mtkView: MTKView?
        var renderer: MetalImageRenderer?
        var loadedURL: URL?
        var visualAdjustments = VisualAdjustments()
        var onVideoSizeKnown: ((CGSize) -> Void)?
        var onPlaybackUpdate: ((PlaybackState) -> Void)?
        var onPlaybackError: (() -> Void)?

        private var player: AVPlayer?
        private var playerItem: AVPlayerItem?
        private var videoOutput: AVPlayerItemVideoOutput?
        private var textureCache: CVMetalTextureCache?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var lastReportedSize: CGSize?
        private var loopA: Double?
        private var loopB: Double?
        private var intermediate: MTLTexture?
        private var isRoomActive = true

        var currentTime: Double {
            player?.currentTime().seconds ?? 0
        }

        func attach(to view: MTKView) {
            mtkView = view
            if let device = renderer?.device {
                CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            }
        }

        func load(url: URL) {
            cleanupPlayer()
            loadedURL = url
            guard let renderer else { return }

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
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.seek(to: 0)
                    if self?.isRoomActive == true {
                        self?.play()
                    }
                }
            }

            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onPlaybackError?()
                }
            }

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.handleTimeUpdate(time.seconds)
                }
            }

            if renderer.device.currentAllocatedSize >= 0, isRoomActive {
                play()
            }
        }

        func play() {
            isRoomActive = true
            player?.play()
        }

        func pause() {
            player?.pause()
        }

        func seek(to seconds: Double) {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        func setMuted(_ muted: Bool) {
            player?.isMuted = muted
            reportPlaybackState()
        }

        func setLoopBounds(a: Double?, b: Double?) {
            loopA = a
            loopB = b
        }

        func setRoomActive(_ active: Bool) {
            guard isRoomActive != active else { return }
            isRoomActive = active
            if active {
                play()
            } else {
                pause()
            }
        }

        func cleanup() {
            cleanupPlayer()
            intermediate = nil
            textureCache = nil
            renderer = nil
            mtkView = nil
            onVideoSizeKnown = nil
            onPlaybackUpdate = nil
            onPlaybackError = nil
        }

        private func cleanupPlayer() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
            player?.pause()
            if let videoOutput {
                playerItem?.remove(videoOutput)
            }
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

        private func handleTimeUpdate(_ seconds: Double) {
            if let loopA, let loopB, seconds >= loopB - (1.0 / 60.0) {
                seek(to: loopA)
            }
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
                PlaybackState(
                    currentTime: currentTime ?? player.currentTime().seconds,
                    duration: duration.isFinite ? duration : 0,
                    paused: player.timeControlStatus != .playing,
                    muted: player.isMuted,
                    buffered: buffered
                )
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            intermediate = nil
        }

        func draw(in view: MTKView) {
            guard let renderer,
                  let output = videoOutput,
                  let textureCache,
                  let drawable = view.currentDrawable,
                  let finalPassDesc = view.currentRenderPassDescriptor,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                return
            }

            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: itemTime),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
                  let sourceTexture = makeTexture(from: pixelBuffer, cache: textureCache) else {
                return
            }
            reportSizeIfNeeded(pixelBuffer)

            let sharpen = Float(visualAdjustments.clampedSharpenAmount)
            let useRCAS = sharpen > 0.001
            let drawableW = drawable.texture.width
            let drawableH = drawable.texture.height
            var pass2InputTexture: MTLTexture = sourceTexture

            if useRCAS {
                let interW = min(max(sourceTexture.width, drawableW), drawableW * 2)
                let interH = min(max(sourceTexture.height, drawableH), drawableH * 2)
                if let intermediateTex = ensureIntermediate(
                    device: renderer.device,
                    width: interW,
                    height: interH,
                    pixelFormat: view.colorPixelFormat
                ) {
                    let pass1Desc = MTLRenderPassDescriptor()
                    pass1Desc.colorAttachments[0].texture = intermediateTex
                    pass1Desc.colorAttachments[0].loadAction = .clear
                    pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    pass1Desc.colorAttachments[0].storeAction = .store

                    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) {
                        encoder.setRenderPipelineState(renderer.rcasPipelineState)
                        encoder.setFragmentTexture(sourceTexture, index: 0)
                        var uniforms = VideoRCASUniforms(brightness: 0, contrast: 1, saturation: 1, sharpen: sharpen)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoRCASUniforms>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        encoder.endEncoding()
                        pass2InputTexture = intermediateTex
                    }
                }
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPassDesc) else {
                return
            }

            let didSupersample = pass2InputTexture.width > drawableW || pass2InputTexture.height > drawableH
            encoder.setRenderPipelineState(renderer.pipelineState)
            encoder.setFragmentTexture(pass2InputTexture, index: 0)
            var uniforms = VideoAAUniforms(
                brightness: Float(visualAdjustments.brightness),
                contrast: Float(visualAdjustments.contrast),
                saturation: Float(visualAdjustments.saturation),
                applyResolve: didSupersample ? 1.0 : 0.0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoAAUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                return nil
            }
            return texture
        }

        private func reportSizeIfNeeded(_ pixelBuffer: CVPixelBuffer) {
            let size = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            guard size.width > 0, size.height > 0, lastReportedSize != size else { return }
            lastReportedSize = size
            onVideoSizeKnown?(size)
        }

        private func ensureIntermediate(
            device: MTLDevice,
            width: Int,
            height: Int,
            pixelFormat: MTLPixelFormat
        ) -> MTLTexture? {
            if let existing = intermediate,
               existing.width == width,
               existing.height == height,
               existing.pixelFormat == pixelFormat {
                return existing
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            let texture = device.makeTexture(descriptor: desc)
            intermediate = texture
            return texture
        }
    }
}
