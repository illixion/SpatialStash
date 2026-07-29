/*
 Spatial Stash - Depth Cache Reader

 Playback-time consumer of a DepthCacheStore entry: sequentially decodes the
 HEVC depth video in lockstep with the main video, serving the depth frame whose
 PTS matches the frame the pump just pulled — exact image/depth sync at any
 frame rate, no inference.

 An entry holds one or two depth files: two-pass (high-frame-rate) conversions
 write the even half of the frames to depth.mov and the odd half to depth-b.mov
 (see DepthConverter). Each file is decoded by its own sequential stream and the
 reader merges them by PTS. While only pass 1 exists, the gaps are served with
 the nearest earlier depth frame — ≤1 frame of depth lag, never wrong-scene
 depth (the lattice is uniform, so the neighbor is always 1 frame away).

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
    /// Bound on decode work per stream per pump tick (a rebuild lands near the
    /// target, so this is only a runaway guard).
    private static let maxDecodesPerCall = 120
    /// Cap on retained decoded-but-not-yet-displayed frames per stream.
    private static let maxLookahead = 8
    /// Throttle for growing-entry refreshes: fresh-asset rebuilds, meta.json
    /// re-reads, and probing for the second pass's file appearing.
    private static let growingRefreshInterval: CFTimeInterval = 2

    private struct DecodedDepth {
        let pts: CMTime
        let texture: MTLTexture
        let keepAlive: [Any]
    }

    /// Sequential decode state for one depth file. Two-pass entries have two
    /// streams (even/odd frame lattices) merged by PTS; single-pass entries one.
    private final class Stream {
        let url: URL
        let isSecondary: Bool
        var asset: AVURLAsset
        var track: AVAssetTrack?
        var trackLoadAttempted = false
        var reader: AVAssetReader?
        var readerOutput: AVAssetReaderTrackOutput?
        var readerAtEnd = false
        /// Decoded frames, ascending PTS.
        var lookahead: [DecodedDepth] = []
        var lastGrowingRebuild: CFTimeInterval = 0
        var lastFileSize: Int64?

        init(url: URL, isSecondary: Bool = false) {
            self.url = url
            self.isSecondary = isSecondary
            self.asset = AVURLAsset(url: url)
        }
    }

    private struct MetaFileStamp: Equatable {
        let modificationDate: Date?
        let fileSize: Int64?
    }

    private let directory: URL
    /// Refreshed from disk while the entry is still growing (progressive).
    private var meta: DepthCacheStore.Meta
    private var progress: DepthCacheStore.Progress?
    /// True while the conversion is still writing this entry: the fragmented
    /// files grow, so EOF means "no more frames YET" — rebuild with a fresh
    /// asset (throttled) to pick up new fragments, re-read meta.json, and
    /// watch for the second pass's file appearing.
    private var progressive: Bool
    private var streams: [Stream]
    private var lastSecondaryProbe: CFTimeInterval = 0
    private var lastMetaProbe: CFTimeInterval = 0
    private var textureCache: CVMetalTextureCache?
    private let metaRefreshQueue = DispatchQueue(label: "com.spatialstash.depth-cache-meta", qos: .utility)
    private let metaRefreshLock = NSLock()
    private var knownMetaStamp: MetaFileStamp?
    private var pendingMeta: (DepthCacheStore.Meta, MetaFileStamp)?
    private var metaRefreshInFlight = false
    private var invalidated = false

    /// Half of the typical frame duration — the PTS match tolerance.
    private var halfFrame: Double
    private let uvScale: SIMD2<Float>
    private let uvOffset: SIMD2<Float>

    init(entry: DepthCacheStore.Entry, device: MTLDevice) {
        // LRU stamp: playback keeps this entry from budget eviction.
        DepthCacheStore.touch(entry)
        self.directory = entry.directory
        self.meta = entry.meta
        self.progress = DepthCacheStore.readProgress(in: entry.directory)
        self.progressive = !entry.meta.completed
        self.streams = [Stream(url: entry.depthVideoURL)]
        if FileManager.default.fileExists(atPath: entry.secondaryDepthVideoURL.path) {
            streams.append(Stream(url: entry.secondaryDepthVideoURL, isSecondary: true))
        }
        knownMetaStamp = Self.metaFileStamp(in: entry.directory)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        uvScale = SIMD2(entry.meta.uvScaleX, entry.meta.uvScaleY)
        uvOffset = SIMD2(entry.meta.uvOffsetX, entry.meta.uvOffsetY)
        halfFrame = Self.halfFrame(for: entry.meta)
    }

    private static func halfFrame(for meta: DepthCacheStore.Meta) -> Double {
        let pts = meta.framePTS
        if pts.count > 1 {
            let deltas = zip(pts.dropFirst(), pts).map(-).filter { $0 > 0 }.sorted()
            return deltas.isEmpty ? 1.0 / 60 : deltas[deltas.count / 2] / 2
        } else if meta.frameCount > 0, meta.duration > 0 {
            return meta.duration / Double(meta.frameCount) / 2
        }
        return 1.0 / 60
    }

    // MARK: Lookup (pump queue)

    /// The depth frame matching `itemTime`, or nil during a post-seek rebuild
    /// gap. The returned texture stays valid until the next `depth(at:)` call
    /// (entries are only pruned then), which outlives the pump tick's warp wait.
    func depth(at itemTime: CMTime) -> PumpFrameDepth? {
        let t = itemTime.seconds
        guard t.isFinite else { return nil }

        applyPendingMeta()
        requestMetaRefreshIfNeeded()
        discoverSecondaryIfNeeded()
        for stream in streams {
            advance(stream, to: t)
        }

        let decoded = streams.flatMap(\.lookahead)
        // 1.5x tolerance: on a full-rate lattice neighbors sit at 2x halfFrame
        // (no false cross-frame match), while on a half-rate first pass the
        // in-between video frames sit at exactly 1x halfFrame from both
        // neighbors — bare halfFrame would make that a float coin-flip.
        if let match = decoded
            .filter({ abs($0.pts.seconds - t) <= halfFrame * 1.5 })
            .min(by: { abs($0.pts.seconds - t) < abs($1.pts.seconds - t) }) {
            // Prune relative to the served frame, never past it — its texture
            // must stay retained until the pump's warp is done with it.
            prune(before: match.pts.seconds)
            return frameDepth(for: match)
        }
        // Decoded past t without a match (a PTS gap, or a half-rate first
        // pass) — serve the newest frame at/before t rather than dropping
        // depth. Requires a frame beyond t so a progressive underrun at the
        // frontier still degrades to flat instead of holding stale depth.
        if decoded.contains(where: { $0.pts.seconds > t + halfFrame }) {
            if let previous = decoded
                .filter({ $0.pts.seconds <= t + halfFrame })
                .max(by: { $0.pts.seconds < $1.pts.seconds }) {
                prune(before: previous.pts.seconds)
                return frameDepth(for: previous)
            }
            return nil
        }
        // Hold the final frame briefly past the end (container rounding).
        if streams.allSatisfy(\.readerAtEnd),
           let last = decoded.max(by: { $0.pts.seconds < $1.pts.seconds }),
           t - last.pts.seconds < halfFrame * 4 {
            return frameDepth(for: last)
        }
        return nil
    }

    /// Pump is shutting down — release the readers and decoded frames.
    func invalidate() {
        metaRefreshLock.lock()
        invalidated = true
        pendingMeta = nil
        metaRefreshLock.unlock()
        for stream in streams {
            stream.reader?.cancelReading()
            stream.reader = nil
            stream.readerOutput = nil
            stream.lookahead.removeAll()
        }
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    // MARK: Internals

    /// While the entry is growing, a two-pass conversion's second file can
    /// appear at any time — pick it up so already-running playback upgrades
    /// to full-rate depth as the frames stream in.
    private func discoverSecondaryIfNeeded() {
        guard progressive, streams.count == 1 else { return }
        let now = CACurrentMediaTime()
        guard now - lastSecondaryProbe > Self.growingRefreshInterval else { return }
        lastSecondaryProbe = now
        let url = directory.appendingPathComponent(DepthCacheStore.secondaryDepthVideoFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            streams.append(Stream(url: url, isSecondary: true))
        }
    }

    private static func metaFileStamp(in directory: URL) -> MetaFileStamp? {
        let url = directory.appendingPathComponent(DepthCacheStore.metaFilename)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return MetaFileStamp(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize.map(Int64.init)
        )
    }

    private func requestMetaRefreshIfNeeded() {
        guard progressive else { return }
        let now = CACurrentMediaTime()
        guard now - lastMetaProbe > Self.growingRefreshInterval else { return }
        lastMetaProbe = now
        guard let stamp = Self.metaFileStamp(in: directory) else { return }

        metaRefreshLock.lock()
        let shouldRefresh = !invalidated && !metaRefreshInFlight && stamp != knownMetaStamp
        if shouldRefresh { metaRefreshInFlight = true }
        metaRefreshLock.unlock()
        guard shouldRefresh else { return }

        let directory = self.directory
        metaRefreshQueue.async { [weak self] in
            let refreshed = DepthCacheStore.readMeta(in: directory)
            guard let self else { return }
            self.metaRefreshLock.lock()
            defer {
                self.metaRefreshInFlight = false
                self.metaRefreshLock.unlock()
            }
            guard !self.invalidated, let refreshed else { return }
            self.pendingMeta = (refreshed, stamp)
        }
    }

    private func applyPendingMeta() {
        metaRefreshLock.lock()
        let update = pendingMeta
        pendingMeta = nil
        if let update { knownMetaStamp = update.1 }
        metaRefreshLock.unlock()
        guard let update else { return }
        meta = update.0
        progressive = !update.0.completed
        halfFrame = Self.halfFrame(for: update.0)
    }

    /// Rebuild if `t` left the stream's window, then decode until the stream
    /// has a frame past `t` (or hits EOF / the per-tick budget).
    private func advance(_ stream: Stream, to t: Double) {
        guard ensureTrack(stream) else { return }

        let oldest = stream.lookahead.first?.pts.seconds
        let newest = stream.lookahead.last?.pts.seconds
        // Progressive: EOF just means the conversion hasn't written this far
        // yet — a (throttled) rebuild with a fresh asset picks up new fragments.
        let growingCatchUp = stream.readerAtEnd && progressive
            && (newest.map { t > $0 + halfFrame } ?? true)
            && CACurrentMediaTime() - stream.lastGrowingRebuild > Self.growingRefreshInterval
            && streamHasReadableProgress(stream, at: t)
            && streamFileHasGrown(stream)
        // Seek after EOF (A-B loop / restart). Empty-lookahead EOF on a
        // growing file means "ahead of the frontier" — that belongs to the
        // throttled catch-up below, or an underrun would rebuild a fresh
        // asset on every pump tick.
        let seekAfterEOF = stream.readerAtEnd
            && (newest.map { t < $0 - halfFrame } ?? !progressive)
        let needsRebuild =
            (stream.reader == nil && !stream.readerAtEnd)                // first use
            || (oldest.map { t < $0 - halfFrame } ?? false)              // backward jump
            || (newest.map { t - $0 > Self.forwardRebuildGap } ?? false) // forward jump
            || seekAfterEOF
            || growingCatchUp
        if needsRebuild {
            rebuild(stream, at: t)
        }

        var iterations = 0
        while iterations < Self.maxDecodesPerCall, !stream.readerAtEnd {
            if let last = stream.lookahead.last, last.pts.seconds > t + halfFrame { break }
            decodeNext(stream)
            iterations += 1
        }
    }

    private func prune(before t: Double) {
        for stream in streams {
            stream.lookahead.removeAll { $0.pts.seconds < t - halfFrame }
            if stream.lookahead.count > Self.maxLookahead {
                stream.lookahead.removeFirst(stream.lookahead.count - Self.maxLookahead)
            }
        }
    }

    private func streamHasReadableProgress(_ stream: Stream, at time: Double) -> Bool {
        guard stream.isSecondary else { return true }
        if let refreshed = DepthCacheStore.readProgress(in: directory) {
            progress = refreshed
        }
        guard let frontier = progress?.secondaryFrontier else { return false }
        return time <= frontier + halfFrame
    }

    private func streamFileHasGrown(_ stream: Stream) -> Bool {
        guard let size = currentFileSize(at: stream.url) else { return false }
        return stream.lastFileSize.map { size > $0 } ?? true
    }

    private func currentFileSize(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func frameDepth(for decoded: DecodedDepth) -> PumpFrameDepth {
        // Per-frame display mapping by nearest PTS (binary search).
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
    private func ensureTrack(_ stream: Stream) -> Bool {
        if stream.track != nil { return true }
        guard !stream.trackLoadAttempted else { return false }
        stream.trackLoadAttempted = true

        final class Box: @unchecked Sendable { var value: AVAssetTrack? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let asset = stream.asset
        Task.detached {
            box.value = try? await asset.loadTracks(withMediaType: .video).first
            semaphore.signal()
        }
        semaphore.wait()
        stream.track = box.value
        if stream.track == nil {
            AppLogger.videoCache.error("Depth cache video has no readable track: \(stream.url.lastPathComponent, privacy: .public)")
        }
        return stream.track != nil
    }

    private func rebuild(_ stream: Stream, at t: Double) {
        stream.reader?.cancelReading()
        stream.reader = nil
        stream.readerOutput = nil
        stream.lookahead.removeAll()
        stream.readerAtEnd = false

        // A growing entry needs a FRESH asset each rebuild — AVURLAsset caches
        // the container structure at parse time and never sees later fragments.
        // Also refresh meta.json (new display-mapping frames; completed flag).
        if progressive {
            stream.lastGrowingRebuild = CACurrentMediaTime()
            stream.asset = AVURLAsset(url: stream.url)
            stream.track = nil
            stream.trackLoadAttempted = false
            guard ensureTrack(stream) else { return }
        }

        guard let track = stream.track, let newReader = try? AVAssetReader(asset: stream.asset) else { return }
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
        stream.reader = newReader
        stream.readerOutput = output
        stream.lastFileSize = currentFileSize(at: stream.url)
    }

    private func decodeNext(_ stream: Stream) {
        guard let readerOutput = stream.readerOutput, let textureCache else {
            stream.readerAtEnd = true
            return
        }
        guard let sample = readerOutput.copyNextSampleBuffer() else {
            stream.readerAtEnd = true
            if stream.reader?.status == .failed {
                AppLogger.videoCache.error("Depth cache decode failed: \(stream.reader?.error?.localizedDescription ?? "unknown", privacy: .public)")
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

        stream.lookahead.append(DecodedDepth(pts: pts, texture: texture, keepAlive: [cvTexture, pixelBuffer]))
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
    let prefersDenseWarpGrid = true

    func frameDepth(itemTime: CMTime, frame: CVPixelBuffer) -> PumpFrameDepth? {
        reader.depth(at: itemTime)
    }

    func invalidate() {
        reader.invalidate()
    }
}
