/*
 Hypnos - Atmos object audio, streamed from the Atmos Objects plugin

 The plugin decodes a film's TrueHD track into its Atmos elements (beds and
 objects) and serves them live from wherever playback is: a layout
 (scene.json), then fixed-length segments as FLAC channel groups plus an
 events file (positions and gains) that opens with a snapshot of every
 element, so a segment stands alone. See JellyfinPlugin/README.md.

 Each element plays through its own RealityKit `AudioGeneratorController`,
 whose render callback reads here. They must stay sample-locked to each
 other: objects are clusters of one mix, and a few ms of skew between them
 comb-filters. Measured on visionOS 27, each generator runs on its **own**
 sample timeline (origins spread 50 ms across 14 generators), so sample
 times can't be compared between channels. The host clock is the shared
 reference: on its first render each channel converts its host time to a
 scene frame against one shared anchor, stores the offset to its own sample
 time, and from then on reads at `sampleTime + offset`, sample-continuous.

 The anchor is chosen by the transport (`start(at:anchorHostTime:)`): "scene
 frame F plays at host time H". Choosing it up front, rather than taking
 whichever render comes first, is what lets the picture be scheduled
 against the same instant. Renders stamped before H are silent.

 Moved from the app's Atmos spike (Services/AtmosSpike.swift), which keeps
 its own copy until the film player replaces it.
 */

import AVFoundation
import Foundation
import os
import RealityKit
import Synchronization

// MARK: - Scene layout and tracks

public struct AtmosScene: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public let id: Int
        public let channel: Int
        public let kind: String
        public let bedChannel: String?

        public var isBed: Bool { kind == "bed" }
    }

    public struct Event: Decodable, Sendable {
        let id: Int
        let t: Int
        let ramp: Int
        let gain: Double
        let pos: [Double]?
    }

    public let sampleRate: Int
    public let elements: [Element]
    public let frameCount: Int
    public let segmentFrames: Int
    public let segmentCount: Int
    /// Audio channels carried by each group's FLAC file, in file channel order.
    public let groups: [[Int]]
    /// Container time of scene frame 0 (the TrueHD track's first access unit).
    public let startSeconds: Double
}

/// One element's position/gain timeline within a segment, sampled by frame.
public struct AtmosElementTrack: Sendable {
    struct Keyframe: Sendable {
        let t: Int
        let ramp: Int
        let pos: SIMD3<Float>
        let gainDB: Float
    }

    let keyframes: [Keyframe]

    init(events: [AtmosScene.Event]) {
        var last = SIMD3<Float>(0, 1, 0)
        keyframes = events.sorted { $0.t < $1.t }.map { event in
            if let p = event.pos, p.count == 3 {
                last = SIMD3(Float(p[0]), Float(p[1]), Float(p[2]))
            }
            return Keyframe(t: event.t, ramp: event.ramp, pos: last, gainDB: Float(event.gain))
        }
    }

    /// DAMF room position (x −1 left…+1 right, y −1 back…+1 front, z 0 ear…1 ceiling) and gain in dB.
    public func state(at frame: Int) -> (pos: SIMD3<Float>, gainDB: Float) {
        guard let first = keyframes.first else { return (SIMD3(0, 1, 0), 0) }
        var lo = 0, hi = keyframes.count - 1, index = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if keyframes[mid].t <= frame { index = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard index >= 0 else { return (first.pos, first.gainDB) }
        let key = keyframes[index]
        guard index > 0, key.ramp > 0, frame < key.t + key.ramp else { return (key.pos, key.gainDB) }
        let prev = keyframes[index - 1]
        let u = Float(frame - key.t) / Float(key.ramp)
        return (prev.pos + (key.pos - prev.pos) * u, prev.gainDB + (key.gainDB - prev.gainDB) * u)
    }
}

// MARK: - Render side

/// The decoded PCM plus everything the render callbacks touch. The main
/// actor writes targets (gain, transport); render threads write telemetry
/// (levels, playhead). Plain-pointer fields are single-writer and read
/// racily for display only.
///
/// Samples live in slots, each holding one segment of interleaved Int16
/// frames for every channel, refilled by `AtmosSegmentStreamer` as the
/// playhead moves.
public final class AtmosObjectAudio: @unchecked Sendable {
    public final class Slot: @unchecked Sendable {
        /// Segment held, −1 while empty or being refilled. A writer stores
        /// −1 before touching `samples` and the new index after.
        let segment = Atomic<Int>(-1)
        let samples: UnsafeMutablePointer<Int16>

        init(capacity: Int) {
            samples = .allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
        }

        deinit { samples.deallocate() }
    }

    public let channelCount: Int
    public let frameCount: Int
    public let sampleRate: Double
    public let segmentFrames: Int
    let slots: [Slot]
    /// Channel-0 buffers that needed a segment no slot held.
    public let underruns = Atomic<Int>(0)

    let playing = Atomic<Bool>(false)
    /// Host time at which `startFrame` plays; 0 = take the first render's.
    let anchorHostTime = Atomic<UInt64>(0)
    let startFrame = Atomic<Int>(0)
    /// Latest frame rendered by channel 0 (UI clock).
    public let playhead = Atomic<Int>(0)
    /// Frames rendered by channel 0 since load, for measuring the real render rate.
    public let renderedFrames = Atomic<Int>(0)
    public let fallbackRenders = Atomic<Int>(0)
    /// Host ticks → scene frames.
    private let framesPerTick: Double

    /// Linear gain targets, written by the main actor.
    let targetGain: UnsafeMutablePointer<Float>
    private let currentGain: UnsafeMutablePointer<Float>
    /// Peak |sample| per channel since the UI last read it.
    let peak: UnsafeMutablePointer<Float>
    /// First valid sample time each channel saw after (re)start, and its host time.
    let firstSampleTime: UnsafeMutablePointer<Int64>
    let firstHostTime: UnsafeMutablePointer<UInt64>
    private let fallbackCursor: UnsafeMutablePointer<Int>
    /// Scene frame minus own sample time, fixed at a channel's first render; `.min` = unset.
    private let channelOffset: UnsafeMutablePointer<Int64>
    /// Largest |host-derived frame − played frame| seen per channel, i.e. drift.
    let maxDrift: UnsafeMutablePointer<Int64>

    public init(scene: AtmosScene, slotCount: Int = 6) {
        channelCount = scene.elements.count
        frameCount = scene.frameCount
        sampleRate = Double(scene.sampleRate)
        segmentFrames = scene.segmentFrames
        slots = (0 ..< slotCount).map { _ in Slot(capacity: scene.segmentFrames * scene.elements.count) }

        targetGain = .allocate(capacity: channelCount)
        targetGain.initialize(repeating: 1, count: channelCount)
        currentGain = .allocate(capacity: channelCount)
        currentGain.initialize(repeating: 1, count: channelCount)
        peak = .allocate(capacity: channelCount)
        peak.initialize(repeating: 0, count: channelCount)
        firstSampleTime = .allocate(capacity: channelCount)
        firstSampleTime.initialize(repeating: .min, count: channelCount)
        firstHostTime = .allocate(capacity: channelCount)
        firstHostTime.initialize(repeating: 0, count: channelCount)
        fallbackCursor = .allocate(capacity: channelCount)
        fallbackCursor.initialize(repeating: 0, count: channelCount)
        channelOffset = .allocate(capacity: channelCount)
        channelOffset.initialize(repeating: .min, count: channelCount)
        maxDrift = .allocate(capacity: channelCount)
        maxDrift.initialize(repeating: 0, count: channelCount)

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        framesPerTick = Double(info.numer) / Double(info.denom) / 1e9 * sampleRate
    }

    deinit {
        targetGain.deallocate()
        currentGain.deallocate()
        peak.deallocate()
        firstSampleTime.deallocate()
        firstHostTime.deallocate()
        fallbackCursor.deallocate()
        channelOffset.deallocate()
        maxDrift.deallocate()
    }

    /// Plays scene frame `frame` at host time `anchorHostTime` (mach ticks);
    /// 0 means at the first render.
    public func start(at frame: Int, anchorHostTime anchor: UInt64 = 0) {
        playing.store(false, ordering: .sequentiallyConsistent)
        let clamped = max(0, min(frame, frameCount - 1))
        startFrame.store(clamped, ordering: .sequentiallyConsistent)
        anchorHostTime.store(anchor, ordering: .sequentiallyConsistent)
        for ch in 0 ..< channelCount {
            firstSampleTime[ch] = .min
            firstHostTime[ch] = 0
            fallbackCursor[ch] = clamped
            channelOffset[ch] = .min
            maxDrift[ch] = 0
        }
        playhead.store(clamped, ordering: .relaxed)
        playing.store(true, ordering: .sequentiallyConsistent)
    }

    public func pause() {
        playing.store(false, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    func samples(forSegment segment: Int) -> UnsafePointer<Int16>? {
        for slot in slots where slot.segment.load(ordering: .acquiring) == segment {
            return UnsafePointer(slot.samples)
        }
        return nil
    }

    public func isResident(_ segment: Int) -> Bool { samples(forSegment: segment) != nil }

    /// The generator callback for one element. Built here, in a nonisolated
    /// context, on purpose: a closure written inside a `@MainActor` view
    /// inherits main-actor isolation, and Swift 6 then traps on the audio
    /// thread's first call — which is how the spike's first device run died.
    public func renderHandler(channel: Int) -> Audio.GeneratorRenderHandler {
        { isSilence, timestamp, frameCount, output in
            self.render(channel: channel, isSilence: isSilence, timestamp: timestamp,
                        frameCount: frameCount, output: output)
        }
    }

    func render(
        channel ch: Int,
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount count: AVAudioFrameCount,
        output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let n = Int(count)
        guard playing.load(ordering: .relaxed) else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            isSilence.pointee = true
            return noErr
        }

        let start = startFrame.load(ordering: .relaxed)
        let frame: Int
        let flags = timestamp.pointee.mFlags
        if flags.contains(.sampleTimeValid), flags.contains(.hostTimeValid) {
            let sampleTime = Int64(timestamp.pointee.mSampleTime)
            let hostTime = timestamp.pointee.mHostTime
            var anchor = anchorHostTime.load(ordering: .acquiring)
            if anchor == 0 {
                let (exchanged, original) = anchorHostTime.compareExchange(
                    expected: 0, desired: hostTime, ordering: .acquiringAndReleasing
                )
                anchor = exchanged ? hostTime : original
            }
            // Signed: a render can be stamped before the anchor.
            let hostFrame = Int64(start) + Int64((Double(hostTime) - Double(anchor)) * framesPerTick)
            if channelOffset[ch] == .min {
                channelOffset[ch] = hostFrame - sampleTime
                firstSampleTime[ch] = sampleTime
                firstHostTime[ch] = hostTime
            }
            let played = sampleTime + channelOffset[ch]
            maxDrift[ch] = max(maxDrift[ch], abs(hostFrame - played))
            frame = Int(played)
        } else {
            frame = fallbackCursor[ch]
            fallbackCursor[ch] += n
            fallbackRenders.add(1, ordering: .relaxed)
        }

        let from = currentGain[ch]
        let to = targetGain[ch]
        let step = (to - from) / Float(max(n, 1))
        var gain = from
        var localPeak: Float = 0
        let scale: Float = 1.0 / 32768.0
        let stride = channelCount
        let total = frameCount

        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        var cachedSegment = -1
        var cached: UnsafePointer<Int16>?
        var missing = false
        for i in 0 ..< n {
            let f = frame + i
            var value: Float = 0
            // Silent before the anchor's frame, so a scheduled start begins on time.
            if f >= start, f < total {
                let segment = f / segmentFrames
                if segment != cachedSegment {
                    cachedSegment = segment
                    cached = samples(forSegment: segment)
                    if cached == nil { missing = true }
                }
                if let cached {
                    value = Float(cached[(f - segment * segmentFrames) * stride + ch]) * scale * gain
                }
            }
            out[i] = value
            localPeak = max(localPeak, abs(value))
            gain += step
        }
        currentGain[ch] = to
        // Mono generator, but copy into any further buffers the node asked for.
        for extra in buffers.dropFirst() {
            guard let dst = extra.mData else { continue }
            memcpy(dst, out, n * MemoryLayout<Float>.size)
        }
        peak[ch] = max(peak[ch], localPeak)

        if ch == 0 {
            playhead.store(max(start, min(frame + n, total)), ordering: .relaxed)
            renderedFrames.add(n, ordering: .relaxed)
            if missing { underruns.add(1, ordering: .relaxed) }
        }
        isSilence.pointee = false
        return noErr
    }
}

// MARK: - Streaming

/// Keeps the segments around the playhead decoded into the audio's slots:
/// one behind (a short back-seek stays instant) and `lookahead` ahead.
/// Fetches in playback order, one segment at a time, off the main actor. A
/// segment the server hasn't decoded yet is decoded on request, so the first
/// fetch after a long seek takes a second or two.
public final class AtmosSegmentStreamer: Sendable {
    public let audio: AtmosObjectAudio
    let client: FilmServerClient
    let groups: [[Int]]
    let segmentCount: Int
    let lookahead = 3
    public let fetched = Atomic<Int>(0)
    public let failures = Atomic<Int>(0)
    /// Where the next fetches should centre; the transport moves it on seek
    /// before playback (and so the playhead) gets there.
    let focusFrame = Atomic<Int>(0)
    private let tracks = Mutex<[Int: [Int: AtmosElementTrack]]>([:])
    private let logger = Logger(subsystem: "com.illixion.hypnos", category: "AtmosAudio")

    public init(audio: AtmosObjectAudio, client: FilmServerClient, scene: AtmosScene) {
        self.audio = audio
        self.client = client
        groups = scene.groups
        segmentCount = scene.segmentCount
    }

    public func track(segment: Int, element: Int) -> AtmosElementTrack? {
        tracks.withLock { $0[segment]?[element] }
    }

    public func focus(on frame: Int) {
        focusFrame.store(frame, ordering: .relaxed)
    }

    public func run() async {
        while !Task.isCancelled {
            let playing = audio.playing.load(ordering: .relaxed)
            let frame = playing ? audio.playhead.load(ordering: .relaxed) : focusFrame.load(ordering: .relaxed)
            let current = min(frame / audio.segmentFrames, segmentCount - 1)
            let wanted = Array(max(0, current - 1) ... min(segmentCount - 1, current + lookahead))
            // Nearest first: the playhead's segment, then ahead, then the one behind.
            let order = wanted.sorted { abs($0 - current) + ($0 < current ? 10 : 0) < abs($1 - current) + ($1 < current ? 10 : 0) }
            if let next = order.first(where: { !audio.isResident($0) }) {
                do {
                    try await load(next, keeping: Set(wanted))
                    fetched.add(1, ordering: .relaxed)
                } catch {
                    if Task.isCancelled { return }
                    failures.add(1, ordering: .relaxed)
                    logger.error("Segment \(next) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func load(_ segment: Int, keeping wanted: Set<Int>) async throws {
        // Decode every group before claiming a slot, so the slot is only
        // unavailable for the copy itself.
        let events = try await client.audioEvents(segment: segment)
        var decoded: [(channels: [Int], buffer: AVAudioPCMBuffer)] = []
        for (index, channels) in groups.enumerated() {
            let data = try await client.audioSegment(segment, group: index)
            decoded.append((channels, try Self.decodeFLAC(data)))
        }
        guard let slot = audio.slots.first(where: { !wanted.contains($0.segment.load(ordering: .acquiring)) }) else { return }

        slot.segment.store(-1, ordering: .releasing)
        let stride = audio.channelCount
        let capacity = audio.segmentFrames
        for (channels, buffer) in decoded {
            guard let planes = buffer.floatChannelData else { continue }
            let frames = min(Int(buffer.frameLength), capacity)
            for (k, channel) in channels.enumerated() where k < Int(buffer.format.channelCount) {
                let source = planes[k]
                for f in 0 ..< frames {
                    let v = max(-1, min(source[f], 32767.0 / 32768.0))
                    slot.samples[f * stride + channel] = Int16(v * 32768)
                }
                for f in frames ..< capacity { slot.samples[f * stride + channel] = 0 }
            }
        }
        let byElement = Dictionary(grouping: events, by: \.id).mapValues { AtmosElementTrack(events: $0) }
        tracks.withLock { all in
            all = all.filter { wanted.contains($0.key) }
            all[segment] = byElement
        }
        slot.segment.store(segment, ordering: .releasing)
    }

    /// AVAudioFile only reads from a URL, so the segment takes a trip through tmp.
    private static func decodeFLAC(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atmos-\(UUID().uuidString).flac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        return buffer
    }
}
