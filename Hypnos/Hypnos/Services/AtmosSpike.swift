/*
 Hypnos - Atmos Object Spike (Settings → Developer)

 Answers one question on device: does Atmos object audio, decoded server-side
 and re-rendered by us as RealityKit spatial sources, sound convincing on the
 Vision Pro's speakers? No Dolby code runs here — the scene is prepared off
 device by `truehdd` (TrueHD → DAMF: bed + object stems and a position
 track), then flattened into two files under `Documents/AtmosSpike/<name>/`:

 - `audio.s16le` — raw interleaved 16-bit PCM, one channel per element, in
   the DAMF channel order (beds first, then objects). Memory-mapped, so a
   2-minute 14-channel clip costs page cache rather than 160 MB of heap.
 - `scene.json`  — `{sampleRate, elements:[{id, channel, kind, bedChannel?}],
   events:[{id, t, ramp, gain, pos?}]}`. `t` is a sample position, `pos` is
   DAMF room space (x −1 left…+1 right, y −1 back…+1 front, z 0 ear…1 ceiling),
   `gain` dB. A new position is reached linearly over `ramp` samples.

 Every element gets its own `AudioGeneratorController`. They must stay
 sample-locked to each other — objects are clusters of one mix, so a few ms of
 skew between them comb-filters. Measured on device (visionOS 27): each
 generator runs on its **own** sample timeline — origins spread 2400 frames
 (50 ms) across 14 generators — so sample times cannot be compared between
 channels. The host clock is the shared reference: on its first render each
 channel converts its host time to a scene frame against one shared host
 anchor, stores the offset to its own sample time, and from then on reads at
 `sampleTime + offset`, sample-continuous. `clockReport` shows both the
 timeline spread and any drift of each channel against the host clock.
 */

#if os(visionOS)
import AVFoundation
import Foundation
import os
import RealityKit
import Synchronization

// MARK: - Scene file

struct AtmosSpikeSceneFile: Decodable {
    struct Element: Decodable {
        let id: Int
        let channel: Int
        let kind: String
        let bedChannel: String?
    }

    struct Event: Decodable {
        let id: Int
        let t: Int
        let ramp: Int
        let gain: Double
        let pos: [Double]?
    }

    let sampleRate: Int
    let elements: [Element]
    let events: [Event]
}

/// One element's position/gain timeline, sampled by frame.
struct AtmosSpikeTrack: Sendable {
    struct Keyframe: Sendable {
        let t: Int
        let ramp: Int
        let pos: SIMD3<Float>
        let gainDB: Float
    }

    let keyframes: [Keyframe]

    init(events: [AtmosSpikeSceneFile.Event]) {
        var last = SIMD3<Float>(0, 1, 0)
        keyframes = events.sorted { $0.t < $1.t }.map { event in
            if let p = event.pos, p.count == 3 {
                last = SIMD3(Float(p[0]), Float(p[1]), Float(p[2]))
            }
            return Keyframe(t: event.t, ramp: event.ramp, pos: last, gainDB: Float(event.gain))
        }
    }

    func state(at frame: Int) -> (pos: SIMD3<Float>, gainDB: Float) {
        guard let first = keyframes.first else { return (SIMD3(0, 1, 0), 0) }
        // Last keyframe at or before `frame`.
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

// MARK: - Audio (render thread side)

/// The mapped PCM plus everything the render callbacks touch. Main thread
/// writes targets (gain, transport); render threads write telemetry (levels,
/// playhead). Plain-pointer fields are single-writer and read racily for
/// display only.
final class AtmosSpikeAudio: @unchecked Sendable {
    let channelCount: Int
    let frameCount: Int
    let sampleRate: Double

    private let data: Data
    private let samples: UnsafePointer<Int16>

    let playing = Atomic<Bool>(false)
    /// Host time at which `startFrame` plays; 0 = not yet set.
    let anchorHostTime = Atomic<UInt64>(0)
    /// Host ticks → scene frames.
    private let framesPerTick: Double
    let startFrame = Atomic<Int>(0)
    /// Latest frame rendered by channel 0 (UI clock).
    let playhead = Atomic<Int>(0)
    /// Frames rendered by channel 0 since load, for measuring the real render rate.
    let renderedFrames = Atomic<Int>(0)
    let fallbackRenders = Atomic<Int>(0)

    /// Linear gain targets, written by the main thread.
    let targetGain: UnsafeMutablePointer<Float>
    /// Render-thread gain state, ramped toward `targetGain` per buffer.
    private let currentGain: UnsafeMutablePointer<Float>
    /// Peak |sample| per channel since the UI last read it.
    let peak: UnsafeMutablePointer<Float>
    /// First valid engine sample time each channel saw after (re)start, and
    /// the host time of that same render. If every generator shares one
    /// sample timeline, `sampleTime − hostSeconds × rate` is equal across
    /// channels; if each has its own, it differs by their timeline offsets.
    let firstSampleTime: UnsafeMutablePointer<Int64>
    let firstHostTime: UnsafeMutablePointer<UInt64>
    /// Per-channel cursors, used only when a timestamp carries no sample/host time.
    private let fallbackCursor: UnsafeMutablePointer<Int>
    /// Scene frame minus own sample time, fixed at a channel's first render; `.min` = unset.
    private let channelOffset: UnsafeMutablePointer<Int64>
    /// Largest |host-derived frame − played frame| seen per channel, i.e. drift.
    let maxDrift: UnsafeMutablePointer<Int64>

    init(url: URL, channelCount: Int, sampleRate: Double) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= channelCount * 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        frameCount = data.count / (channelCount * 2)
        // Data backed by a mapping keeps its bytes at a stable address for its lifetime.
        samples = data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Int16.self) }

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

    /// Main thread: play from `frame` on the next render cycle.
    func start(at frame: Int) {
        playing.store(false, ordering: .sequentiallyConsistent)
        let clamped = max(0, min(frame, frameCount - 1))
        startFrame.store(clamped, ordering: .sequentiallyConsistent)
        anchorHostTime.store(0, ordering: .sequentiallyConsistent)
        for ch in 0..<channelCount {
            firstSampleTime[ch] = .min
            firstHostTime[ch] = 0
            fallbackCursor[ch] = clamped
            channelOffset[ch] = .min
            maxDrift[ch] = 0
        }
        playhead.store(clamped, ordering: .relaxed)
        playing.store(true, ordering: .sequentiallyConsistent)
    }

    func pause() {
        playing.store(false, ordering: .sequentiallyConsistent)
    }

    /// The generator callback for one element. Built here, in a nonisolated
    /// context, on purpose: a closure written inside a `@MainActor` view
    /// inherits main-actor isolation, and Swift 6 then traps on the audio
    /// thread's first call (`_swift_task_checkIsolatedSwift` → dispatch
    /// queue assertion) — which is exactly how the first device run died.
    func renderHandler(channel: Int) -> Audio.GeneratorRenderHandler {
        { isSilence, timestamp, frameCount, output in
            self.render(channel: channel, isSilence: isSilence, timestamp: timestamp,
                        frameCount: frameCount, output: output)
        }
    }

    /// Render callback body for one element (mono output). Loops at the end.
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
            // Signed: a channel may render a buffer stamped before the anchor.
            let hostFrame = Int64(startFrame.load(ordering: .relaxed))
                + Int64((Double(hostTime) - Double(anchor)) * framesPerTick)
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
        for i in 0..<n {
            let f = frame + i
            var value: Float = 0
            if f >= 0 {
                let index = f % total
                value = Float(samples[index * stride + ch]) * scale * gain
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
            playhead.store((frame + n) % total, ordering: .relaxed)
            renderedFrames.add(n, ordering: .relaxed)
        }
        isSilence.pointee = false
        return noErr
    }
}

// MARK: - Model (main actor)

@MainActor
@Observable
final class AtmosSpikeModel {
    static let shared = AtmosSpikeModel()

    static var scenesDirectory: URL {
        LocalMediaSource.documentsDirectory.appendingPathComponent("AtmosSpike", isDirectory: true)
    }

    struct Element {
        let id: Int
        let channel: Int
        let isBed: Bool
        let bedChannel: String?
        let track: AtmosSpikeTrack
    }

    // Library
    private(set) var availableScenes: [URL] = []
    private(set) var loadedScene: URL?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var elements: [Element] = []
    @ObservationIgnored private(set) var audio: AtmosSpikeAudio?

    // Transport
    private(set) var isPlaying = false
    var isSpaceOpen = false

    // Tuning — read by the immersive view every tick.
    var masterGainDB: Float = 0
    var lfeGainDB: Float = 0
    var reverbDB: Float = 0
    var roomHalfWidth: Float = 2.0
    var roomHalfDepth: Float = 2.5
    var roomHeight: Float = 1.6
    var earHeight: Float = 1.55
    var flattenHeights = false
    var showSpheres = true

    // Telemetry
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var measuredRate: Double = 0
    private(set) var clockReport = "—"
    /// Smoothed per-channel level (0…1), for sphere scaling.
    private(set) var levels: [Float] = []

    @ObservationIgnored private var rateSample: (frames: Int, time: ContinuousClock.Instant)?
    @ObservationIgnored private var lastTelemetry = ContinuousClock.now
    @ObservationIgnored private var lastLog = ContinuousClock.now

    private init() {}

    func refreshScenes() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.scenesDirectory, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.scenesDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        availableScenes = dirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("scene.json").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func load(_ directory: URL) async {
        guard !isLoading else { return }
        stop()
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let (file, audio) = try await Task.detached(priority: .userInitiated) {
                let json = try Data(contentsOf: directory.appendingPathComponent("scene.json"))
                let file = try JSONDecoder().decode(AtmosSpikeSceneFile.self, from: json)
                let audio = try AtmosSpikeAudio(
                    url: directory.appendingPathComponent("audio.s16le"),
                    channelCount: file.elements.count,
                    sampleRate: Double(file.sampleRate)
                )
                return (file, audio)
            }.value

            let byId = Dictionary(grouping: file.events, by: \.id)
            elements = file.elements.sorted { $0.channel < $1.channel }.map { element in
                Element(
                    id: element.id,
                    channel: element.channel,
                    isBed: element.kind == "bed",
                    bedChannel: element.bedChannel,
                    track: AtmosSpikeTrack(events: byId[element.id] ?? [])
                )
            }
            self.audio = audio
            loadedScene = directory
            levels = Array(repeating: 0, count: elements.count)
            durationSeconds = Double(audio.frameCount) / audio.sampleRate
            positionSeconds = 0
            AppLogger.atmosSpike.info("Loaded \(directory.lastPathComponent, privacy: .public): \(file.elements.count) elements, \(file.events.count) events, \(self.durationSeconds, format: .fixed(precision: 1))s")
        } catch {
            loadError = error.localizedDescription
            AppLogger.atmosSpike.error("Load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Transport

    func play() {
        guard let audio else { return }
        audio.start(at: audio.playhead.load(ordering: .relaxed))
        isPlaying = true
        rateSample = nil
    }

    func pause() {
        audio?.pause()
        isPlaying = false
    }

    func stop() {
        audio?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        guard let audio else { return }
        let frame = Int(max(0, min(seconds, durationSeconds)) * audio.sampleRate)
        if isPlaying {
            audio.start(at: frame)
        } else {
            audio.playhead.store(frame, ordering: .relaxed)
        }
        positionSeconds = Double(frame) / audio.sampleRate
    }

    // MARK: Per-frame work (called by the immersive view)

    /// World-space position for an element at `frame`, in the immersive
    /// space's coordinates (origin at the floor below the viewer, −z forward).
    func worldPosition(of element: Element, frame: Int) -> SIMD3<Float> {
        let p = element.track.state(at: frame).pos
        let z = flattenHeights ? 0 : max(0, min(p.z, 1))
        var local = SIMD3<Float>(p.x * roomHalfWidth, z * roomHeight, -p.y * roomHalfDepth)
        // A source at the listener's head has no direction; keep a minimum radius.
        let minRadius: Float = 0.6
        let length = simd_length(local)
        if length < minRadius {
            local = length > 0.001 ? local / length * minRadius : SIMD3(0, minRadius, 0)
        }
        return local + SIMD3(0, earHeight, 0)
    }

    /// Current playback frame (UI clock; one render buffer behind the audio).
    var currentFrame: Int { audio?.playhead.load(ordering: .relaxed) ?? 0 }

    /// Push gains to the render side and refresh telemetry. Called ~60 Hz.
    func tick() {
        guard let audio else { return }
        let frame = currentFrame
        for element in elements {
            let metaDB = element.track.state(at: frame).gainDB
            let db = masterGainDB + metaDB + (element.isBed ? lfeGainDB : 0)
            audio.targetGain[element.channel] = db <= -120 ? 0 : powf(10, db / 20)
            let p = audio.peak[element.channel]
            audio.peak[element.channel] = 0
            let previous = levels[element.channel]
            levels[element.channel] = max(p, previous * 0.85)
        }

        let now = ContinuousClock.now
        guard now - lastTelemetry > .milliseconds(250) else { return }
        lastTelemetry = now
        positionSeconds = Double(frame) / audio.sampleRate

        let rendered = audio.renderedFrames.load(ordering: .relaxed)
        if isPlaying, let sample = rateSample {
            let dt = now - sample.time
            let seconds = Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18
            if seconds > 2 {
                measuredRate = Double(rendered - sample.frames) / seconds
                rateSample = (rendered, now)
            }
        } else if isPlaying {
            rateSample = (rendered, now)
        }

        // Each channel's timeline origin expressed in frames of host time.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        var origins: [Double] = []
        for ch in 0..<audio.channelCount where audio.firstSampleTime[ch] != .min {
            let hostSeconds = Double(audio.firstHostTime[ch]) * Double(info.numer) / Double(info.denom) / 1e9
            origins.append(Double(audio.firstSampleTime[ch]) - hostSeconds * audio.sampleRate)
        }
        let fallbacks = audio.fallbackRenders.load(ordering: .relaxed)
        if let lo = origins.min(), let hi = origins.max() {
            var drift: Int64 = 0
            for ch in 0..<audio.channelCount { drift = max(drift, audio.maxDrift[ch]) }
            clockReport = "\(origins.count)/\(audio.channelCount) ch host-aligned, own-timeline spread \(Int(hi - lo)) frames, max drift \(drift) frames, fallback renders \(fallbacks)"
        } else if fallbacks > 0 {
            clockReport = "no sample times — per-channel cursors (\(fallbacks) renders)"
        }

        // Same readouts, for `build-and-sign --log` on device.
        if isPlaying, now - lastLog > .seconds(5) {
            lastLog = now
            AppLogger.atmosSpike.info("t=\(self.positionSeconds, format: .fixed(precision: 1))s rate=\(self.measuredRate, format: .fixed(precision: 0))Hz flatten=\(self.flattenHeights) \(self.clockReport, privacy: .public)")
        }
    }
}
#endif
