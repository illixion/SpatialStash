/*
 Spatial Stash - Depth Cache Reader

 Playback-time consumer of a DepthCacheStore entry: sequentially decodes the
 HEVC depth video in lockstep with the main video, serving the depth frame whose
 PTS matches the frame the pump just pulled — exact image/depth sync at any
 frame rate, no inference.

 Decode is sequential (AVAssetReader), which linear playback loves; a seek
 outside the small lookahead window tears the reader down and rebuilds it at the
 target time (~50-100ms once). During that gap the source reports "no depth" and
 the pump renders flat with a short ramp back — never wrong-frame depth.

 All calls happen on the pump queue (single thread); no internal locking.
 */

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os

final class DepthCacheReader: @unchecked Sendable {
    /// Forward PTS gap beyond which decoding through is slower than rebuilding
    /// the reader at the target time.
    private static let forwardRebuildGap = 1.5
    /// Bound on decode work per pump tick (a rebuild lands near the target, so
    /// this is only a runaway guard).
    private static let maxDecodesPerCall = 120
    /// Cap on retained decoded-but-not-yet-displayed frames.
    private static let maxLookahead = 8

    private let entry: DepthCacheStore.Entry
    private let asset: AVURLAsset
    private var textureCache: CVMetalTextureCache?

    private var track: AVAssetTrack?
    private var trackLoadAttempted = false
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var readerAtEnd = false

    private struct DecodedDepth {
        let pts: CMTime
        let texture: MTLTexture
        let keepAlive: [Any]
    }
    /// Decoded frames, ascending PTS.
    private var lookahead: [DecodedDepth] = []

    /// Half of the typical frame duration — the PTS match tolerance.
    private let halfFrame: Double
    private let uvScale: SIMD2<Float>
    private let uvOffset: SIMD2<Float>

    init(entry: DepthCacheStore.Entry, device: MTLDevice) {
        self.entry = entry
        self.asset = AVURLAsset(url: entry.depthVideoURL)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        uvScale = SIMD2(entry.meta.uvScaleX, entry.meta.uvScaleY)
        uvOffset = SIMD2(entry.meta.uvOffsetX, entry.meta.uvOffsetY)

        let pts = entry.meta.framePTS
        if pts.count > 1 {
            let deltas = zip(pts.dropFirst(), pts).map(-).filter { $0 > 0 }.sorted()
            halfFrame = deltas.isEmpty ? 1.0 / 60 : deltas[deltas.count / 2] / 2
        } else if entry.meta.frameCount > 0, entry.meta.duration > 0 {
            halfFrame = entry.meta.duration / Double(entry.meta.frameCount) / 2
        } else {
            halfFrame = 1.0 / 60
        }
    }

    // MARK: Lookup (pump queue)

    /// The depth frame matching `itemTime`, or nil during a post-seek rebuild
    /// gap. The returned texture stays valid until the next `depth(at:)` call
    /// (entries are only pruned then), which outlives the pump tick's warp wait.
    func depth(at itemTime: CMTime) -> PumpFrameDepth? {
        let t = itemTime.seconds
        guard t.isFinite, ensureTrack() else { return nil }

        if let match = match(t) {
            prune(before: t)
            return frameDepth(for: match)
        }

        let oldest = lookahead.first?.pts.seconds
        let newest = lookahead.last?.pts.seconds
        let needsRebuild =
            (reader == nil && !readerAtEnd)                              // first use
            || (oldest.map { t < $0 - halfFrame } ?? false)              // backward jump
            || (newest.map { t - $0 > Self.forwardRebuildGap } ?? false) // forward jump
            || (readerAtEnd && (newest.map { t < $0 - halfFrame } ?? true)) // seek after EOF (A-B loop / restart)
        if needsRebuild {
            rebuild(at: t)
        }

        var iterations = 0
        while iterations < Self.maxDecodesPerCall {
            if let match = match(t) {
                prune(before: t)
                return frameDepth(for: match)
            }
            // Decoded past t without a match (PTS gap) — serve the newest frame
            // at/before t rather than dropping depth for a frame.
            if let last = lookahead.last, last.pts.seconds > t + halfFrame {
                if let previous = lookahead.last(where: { $0.pts.seconds <= t + halfFrame }) {
                    prune(before: previous.pts.seconds)
                    return frameDepth(for: previous)
                }
                return nil
            }
            if readerAtEnd {
                // Hold the final frame briefly past the end (container rounding).
                if let last = lookahead.last, t - last.pts.seconds < halfFrame * 4 {
                    return frameDepth(for: last)
                }
                return nil
            }
            decodeNext()
            iterations += 1
        }
        return nil
    }

    /// Pump is shutting down — release the reader and decoded frames.
    func invalidate() {
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        lookahead.removeAll()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    // MARK: Internals

    private func match(_ t: Double) -> DecodedDepth? {
        lookahead
            .filter { abs($0.pts.seconds - t) <= halfFrame }
            .min { abs($0.pts.seconds - t) < abs($1.pts.seconds - t) }
    }

    private func prune(before t: Double) {
        lookahead.removeAll { $0.pts.seconds < t - halfFrame }
        if lookahead.count > Self.maxLookahead {
            lookahead.removeFirst(lookahead.count - Self.maxLookahead)
        }
    }

    private func frameDepth(for decoded: DecodedDepth) -> PumpFrameDepth {
        // Per-frame display mapping by nearest PTS (binary search).
        let meta = entry.meta
        var valueScale: Float = 1
        var valueBias: Float = 0
        var median: Float?
        if !meta.framePTS.isEmpty {
            let index = nearestIndex(in: meta.framePTS, to: decoded.pts.seconds)
            if index < meta.displayScale.count { valueScale = meta.displayScale[index] }
            if index < meta.displayBias.count { valueBias = meta.displayBias[index] }
            if index < meta.displayMedian.count { median = meta.displayMedian[index] }
        }
        return PumpFrameDepth(
            texture: decoded.texture, uvScale: uvScale, uvOffset: uvOffset,
            valueScale: valueScale, valueBias: valueBias, median: median
        )
    }

    private func nearestIndex(in sorted: [Double], to value: Double) -> Int {
        var lo = 0
        var hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(sorted[lo - 1] - value) < abs(sorted[lo] - value) {
            return lo - 1
        }
        return lo
    }

    /// One-time synchronous bridge for the async track load (pump queue only;
    /// the load itself runs on AVFoundation's queues, so no deadlock).
    private func ensureTrack() -> Bool {
        if track != nil { return true }
        guard !trackLoadAttempted else { return false }
        trackLoadAttempted = true

        final class Box: @unchecked Sendable { var value: AVAssetTrack? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let asset = self.asset
        Task.detached {
            box.value = try? await asset.loadTracks(withMediaType: .video).first
            semaphore.signal()
        }
        semaphore.wait()
        track = box.value
        if track == nil {
            AppLogger.videoCache.error("Depth cache video has no readable track: \(self.entry.depthVideoURL.lastPathComponent, privacy: .public)")
        }
        return track != nil
    }

    private func rebuild(at t: Double) {
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        lookahead.removeAll()
        readerAtEnd = false

        guard let track, let newReader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        output.alwaysCopiesSampleData = false
        guard newReader.canAdd(output) else { return }
        newReader.add(output)
        // Start one frame early so the target frame's predecessor tolerance
        // window is covered; the reader starts at the preceding sync frame anyway.
        let start = CMTime(seconds: max(0, t - halfFrame * 2), preferredTimescale: 90_000)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        guard newReader.startReading() else { return }
        reader = newReader
        readerOutput = output
    }

    private func decodeNext() {
        guard let readerOutput, let textureCache else {
            readerAtEnd = true
            return
        }
        guard let sample = readerOutput.copyNextSampleBuffer() else {
            readerAtEnd = true
            if reader?.status == .failed {
                AppLogger.videoCache.error("Depth cache decode failed: \(self.reader?.error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .r8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        lookahead.append(DecodedDepth(pts: pts, texture: texture, keepAlive: [cvTexture, pixelBuffer]))
    }
}

/// Cached-mode depth source: PTS-matched pre-computed depth, no ANE work.
final class CachedDepthSource: PumpDepthSource, @unchecked Sendable {
    private let reader: DepthCacheReader

    init(entry: DepthCacheStore.Entry, device: MTLDevice) {
        self.reader = DepthCacheReader(entry: entry, device: device)
    }

    /// A seek gap must render flat, not fall back to the heuristic warp.
    let flattensWhenUnavailable = true

    func frameDepth(itemTime: CMTime, frame: CVPixelBuffer) -> PumpFrameDepth? {
        reader.depth(at: itemTime)
    }

    func invalidate() {
        reader.invalidate()
    }
}
