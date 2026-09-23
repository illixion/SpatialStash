/*
 Hypnos - film video player

 Feeds the plugin's video segments into an AVSampleBufferDisplayLayer whose
 control timebase runs on the host clock. That clock is also where the
 Atmos audio engine anchors its render timestamps, which is the point: the
 audio can say "film time T plays at host time H" and the picture follows
 with no drift correction, because both sides count the same ticks.

 Decoding and display management are the system's. The layer receives the
 compressed samples with the format description CoreMedia builds from the
 segment's own sample entry, so a dvh1 entry with its Dolby Vision
 configuration reaches the decoder intact.

 A seek flushes the layer, parks the timebase at the target and feeds from
 the keyframe interval containing it. Samples before the target are marked
 do-not-display: they are decoded (later frames depend on them) but never
 shown. Playback resumes at a host time slightly in the future so the
 decoder has caught up to the target by the time it is due.
 */

import AVFoundation
import CoreMedia
import Foundation
import Observation
import os

@MainActor
@Observable
public final class FilmVideoPlayer {
    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Film time, on the host clock.
    public let timebase: CMTimebase

    public private(set) var index: FilmVideoIndex?
    public private(set) var track: FragmentedMP4Track?
    public private(set) var formatSummary = ""
    public private(set) var status = "Idle"
    public private(set) var isPlaying = false
    /// Film time up to which samples have been enqueued.
    public private(set) var bufferedUntil: Double = 0
    public private(set) var currentSegment = 0
    /// Wall time from a seek to the clock starting (the target frame primed).
    public private(set) var lastSeekLatency: Double = 0

    /// How far ahead of the playhead to keep samples enqueued.
    public var aheadSeconds: Double = 12
    /// How far ahead of now a resume is scheduled, so the decoder can reach the target first.
    public var startDelay: Double = 0.2

    private let logger = Logger(subsystem: "com.illixion.hypnos", category: "FilmVideo")
    private var client: FilmServerClient?
    private var format: CMVideoFormatDescription?
    private var feedTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var segments: [Int: Task<FragmentedMP4Segment, Error>] = [:]

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    public init() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        self.timebase = timebase!
        CMTimebaseSetRate(self.timebase, rate: 0)
        displayLayer.controlTimebase = self.timebase
        displayLayer.videoGravity = .resizeAspect
        #if !os(visionOS)
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        #endif
    }

    /// Current film time.
    public var currentTime: Double { CMTimebaseGetTime(timebase).seconds }
    public var duration: Double { index?.durationSeconds ?? 0 }

    // MARK: Transport

    public func load(_ client: FilmServerClient, startAt seconds: Double = 0) async {
        stop()
        self.client = client
        status = "Loading…"
        do {
            let index = try await client.videoIndex()
            let track = try FragmentedMP4Track(initSegment: await client.videoInit())
            let format = try track.makeFormatDescription()
            self.index = index
            self.track = track
            self.format = format
            formatSummary = Self.summarize(format, track: track, index: index)
            logger.info("Loaded \(client.itemID, privacy: .public): \(self.formatSummary, privacy: .public)")
            status = "Ready"
            seek(to: seconds, resume: false)
        } catch {
            status = "Load failed: \(error.localizedDescription)"
            logger.error("\(self.status, privacy: .public)")
        }
    }

    public func play() {
        guard index != nil, !isPlaying else { return }
        isPlaying = true
        start(filmTime: currentTime, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.05, preferredTimescale: 1_000_000_000))
    }

    public func pause() {
        isPlaying = false
        CMTimebaseSetRate(timebase, rate: 0)
    }

    /// Runs the timebase so `filmTime` is due at `hostTime`. This is the hook
    /// an external clock (the Atmos audio engine) uses to lead the picture.
    public func start(filmTime: Double, atHostTime hostTime: CMTime) {
        CMTimebaseSetRateAndAnchorTime(
            timebase, rate: 1,
            anchorTime: CMTime(seconds: filmTime, preferredTimescale: 1_000_000_000),
            immediateSourceTime: hostTime
        )
    }

    public func seek(to seconds: Double, resume: Bool? = nil) {
        guard let index else { return }
        let target = min(max(0, seconds), max(0, index.durationSeconds - 0.5))
        let resume = resume ?? isPlaying
        isPlaying = resume
        feedTask?.cancel()
        startTask?.cancel()
        renderer.flush()
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 1_000_000_000))
        bufferedUntil = target
        let first = index.segment(containing: target)
        segments = segments.filter { abs($0.key - first) <= 2 }
        let requested = Date()
        feedTask = Task { [weak self] in
            await self?.feed(from: first, target: target, resume: resume, requested: requested)
        }
    }

    public func stop() {
        feedTask?.cancel()
        feedTask = nil
        startTask?.cancel()
        segments.values.forEach { $0.cancel() }
        segments.removeAll()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        CMTimebaseSetRate(timebase, rate: 0)
        isPlaying = false
    }

    // MARK: Feeding

    private func feed(from first: Int, target: Double, resume: Bool, requested: Date) async {
        guard let index, let track, let format else { return }
        let timescale = track.timescale
        // Half a frame of slack so a keyframe exactly at the target is displayed.
        let hideBefore = Int64((target - 0.01) * Double(timescale))
        var primed = false
        var n = first
        while n < index.segmentStarts.count, !Task.isCancelled {
            while primed, !Task.isCancelled, bufferedUntil - currentTime > aheadSeconds {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if n + 1 < index.segmentStarts.count {
                prefetch(n + 1 ... min(n + 2, index.segmentStarts.count - 1))
            }
            let segment: FragmentedMP4Segment
            do {
                segment = try await load(segment: n)
            } catch {
                if Task.isCancelled { return }
                segments[n] = nil // retry with a fresh request
                status = "Segment \(n) failed: \(error.localizedDescription)"
                logger.error("\(self.status, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard !Task.isCancelled else { return }
            currentSegment = n

            for sample in segment.samples {
                while !renderer.isReadyForMoreMediaData, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                guard !Task.isCancelled else { return }
                if renderer.status == .failed {
                    status = "Renderer failed: \(renderer.error?.localizedDescription ?? "unknown")"
                    logger.error("\(self.status, privacy: .public)")
                    return
                }
                let hidden = sample.presentationTime < hideBefore
                guard let buffer = Self.makeSampleBuffer(sample, in: segment.data, format: format, timescale: timescale,
                                                         doNotDisplay: hidden)
                else { continue }
                renderer.enqueue(buffer)
                bufferedUntil = max(bufferedUntil, Double(sample.presentationTime + sample.duration) / Double(timescale))

                // Start from the first frame that will be shown. Waiting for the
                // whole segment instead deadlocks: the renderer stops accepting
                // samples once its displayable queue is full, and a parked clock
                // never drains it.
                if !primed, !hidden {
                    primed = true
                    startTask = Task { [weak self] in
                        await self?.startWhenPrimed(target: target, resume: resume, requested: requested)
                    }
                }
            }
            segments[n - 1] = nil
            n += 1
        }
    }

    /// Starts the clock once the renderer has enough queued to play smoothly
    /// (or its queue is full), a moment in the future so the frames decoded
    /// ahead of the target are out of the way.
    private func startWhenPrimed(target: Double, resume: Bool, requested: Date) async {
        let deadline = Date().addingTimeInterval(2)
        while !Task.isCancelled, !renderer.hasSufficientMediaDataForReliablePlaybackStart,
              renderer.isReadyForMoreMediaData, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        lastSeekLatency = Date().timeIntervalSince(requested)
        status = "Playing"
        if resume {
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: startDelay, preferredTimescale: 1_000_000_000)
            start(filmTime: target, atHostTime: host)
        }
    }

    private func prefetch(_ range: ClosedRange<Int>) {
        for n in range where segments[n] == nil {
            _ = segmentTask(n)
        }
    }

    private func load(segment n: Int) async throws -> FragmentedMP4Segment {
        try await segmentTask(n).value
    }

    private func segmentTask(_ n: Int) -> Task<FragmentedMP4Segment, Error> {
        if let existing = segments[n] { return existing }
        guard let client, let track else { return Task { throw CancellationError() } }
        let task = Task.detached(priority: .userInitiated) {
            try FragmentedMP4Segment(data: try await client.videoSegment(n), track: track)
        }
        segments[n] = task
        return task
    }

    // MARK: Sample buffers

    private nonisolated static func makeSampleBuffer(
        _ sample: FragmentedMP4Segment.Sample,
        in data: Data,
        format: CMVideoFormatDescription,
        timescale: Int32,
        doNotDisplay: Bool
    ) -> CMSampleBuffer? {
        let length = sample.range.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!.advanced(by: sample.range.lowerBound),
                blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: sample.duration, timescale: timescale),
            presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: timescale),
            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: timescale)
        )
        var size = length
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }

        if !sample.isSync || doNotDisplay,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if !sample.isSync {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if doNotDisplay {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return buffer
    }

    // MARK: Telemetry

    /// Codec, colour and HDR metadata as CoreMedia understood the sample entry.
    nonisolated static func summarize(_ format: CMVideoFormatDescription, track: FragmentedMP4Track, index: FilmVideoIndex) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = (extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])?
            .keys.sorted().joined(separator: "+") ?? "none"
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "?"
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? "?"
        let mastering = extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil ? " mdcv" : ""
        let lightLevel = extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil ? " clli" : ""
        let profile = index.dvProfile.map { " P\($0)" } ?? ""
        return "\(fourCC(CMFormatDescriptionGetMediaSubType(format))) \(dimensions.width)×\(dimensions.height) atoms \(atoms), "
            + "\(transfer) / \(primaries)\(mastering)\(lightLevel), server says \(index.videoRange)\(profile)"
    }

    nonisolated static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
    }
}
