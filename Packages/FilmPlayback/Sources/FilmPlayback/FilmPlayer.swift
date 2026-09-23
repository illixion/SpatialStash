/*
 Hypnos - film player: picture and Atmos object audio on one clock

 Owns the transport. Every start, whether after a seek or a pause, is
 scheduled rather than immediate:

 1. The picture is parked at the film time T and primed (the frame at T
    queued), and the audio streamer fetches the segment holding T's frame.
 2. Once both are ready, one host time H a moment ahead is chosen.
 3. The audio is told "scene frame F(T) renders at H", and the picture
    "film time T is due at H + output latency + avOffset", since the audio
    rendered at H is heard that much later.

 Film time is the container's clock, which both halves share: the video
 segments are stamped in it and the scene's `startSeconds` places audio
 frame 0 on it. Both halves then run from the host clock, so once started
 they cannot drift apart.

 Items without Atmos objects (the plugin answers 422) play picture only.
 */

import CoreMedia
import Foundation
import Observation
import os
import simd

@MainActor
@Observable
public final class FilmPlayer {
    public let video = FilmVideoPlayer()
    public private(set) var scene: AtmosScene?
    @ObservationIgnored public private(set) var audio: AtmosObjectAudio?
    @ObservationIgnored public private(set) var streamer: AtmosSegmentStreamer?
    public private(set) var isPlaying = false
    public private(set) var status = "Idle"
    public private(set) var audioStatus = "—"

    // Tuning, read by the stage every tick.
    public var masterGainDB: Float = 0
    public var lfeGainDB: Float = 0
    public var reverbDB: Float = 0
    public var roomHalfWidth: Float = 2.0
    public var roomHalfDepth: Float = 2.5
    public var roomHeight: Float = 1.6
    public var flattenHeights = false
    /// Extra picture delay on top of the route's reported latency, in ms.
    /// Positive shows the picture later. RealityKit's own processing isn't
    /// reported anywhere, so this is set by eye and ear.
    public var avOffsetMs: Double = 0 {
        didSet { if isPlaying { resume() } }
    }
    /// Output latency of the current route, as the platform reports it.
    public private(set) var outputLatency: Double = 0
    /// How far ahead a start is scheduled, so both halves are ready when it comes.
    public var startLead: Double = 0.25

    // Telemetry
    public private(set) var levels: [Float] = []
    public private(set) var measuredRate: Double = 0
    public private(set) var clockReport = "—"

    private let logger = Logger(subsystem: "com.illixion.hypnos", category: "FilmPlayer")
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var lastState: [Int: (pos: SIMD3<Float>, gainDB: Float)] = [:]
    @ObservationIgnored private var rateSample: (frames: Int, time: ContinuousClock.Instant)?
    @ObservationIgnored private var lastTelemetry = ContinuousClock.now

    public init() {}

    public var elements: [AtmosScene.Element] { scene?.elements ?? [] }
    /// Film time of the picture.
    public var currentTime: Double { video.currentTime }
    public var duration: Double { video.duration }

    // MARK: Loading

    public func load(_ client: FilmServerClient, startAt seconds: Double = 0) async {
        stop()
        status = "Loading…"
        audioStatus = "Loading…"
        async let videoLoad: Void = video.load(client, startAt: seconds)
        let scene: AtmosScene?
        do {
            scene = try await client.audioScene(startSeconds: seconds)
            audioStatus = scene == nil ? "No Atmos objects; picture only" : "Streaming"
        } catch {
            scene = nil
            audioStatus = "Audio unavailable: \(error.localizedDescription)"
            logger.error("\(self.audioStatus, privacy: .public)")
        }
        await videoLoad

        if let scene {
            let audio = AtmosObjectAudio(scene: scene)
            let streamer = AtmosSegmentStreamer(audio: audio, client: client, scene: scene)
            streamer.focus(on: frame(for: seconds, in: scene))
            self.scene = scene
            self.audio = audio
            self.streamer = streamer
            levels = Array(repeating: 0, count: scene.elements.count)
            streamTask = Task.detached(priority: .userInitiated) { await streamer.run() }
            logger.info("Atmos: \(scene.elements.count) elements, \(scene.segmentCount) segments, start \(scene.startSeconds)s")
        }
        status = video.status
    }

    // MARK: Transport

    public func play() {
        guard !isPlaying, video.index != nil else { return }
        isPlaying = true
        schedule(at: currentTime, seekVideo: false)
    }

    public func pause() {
        startTask?.cancel()
        isPlaying = false
        audio?.pause()
        video.pause()
    }

    public func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.5))
        schedule(at: target, seekVideo: true)
    }

    public func stop() {
        startTask?.cancel()
        streamTask?.cancel()
        streamTask = nil
        audio?.pause()
        video.stop()
        audio = nil
        streamer = nil
        scene = nil
        lastState = [:]
        isPlaying = false
    }

    /// Re-anchors both halves at the current position, e.g. after an offset change.
    private func resume() {
        schedule(at: currentTime, seekVideo: false)
    }

    private func schedule(at filmTime: Double, seekVideo: Bool) {
        startTask?.cancel()
        audio?.pause()
        if seekVideo {
            video.seek(to: filmTime, resume: false)
        } else {
            video.pause()
        }
        guard let audio, let streamer, let scene else {
            if isPlaying { video.play() }
            return
        }
        let frame = frame(for: filmTime, in: scene)
        streamer.focus(on: frame)
        audio.playhead.store(frame, ordering: .relaxed)
        guard isPlaying else { return }

        startTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(15)
            let segment = frame / audio.segmentFrames
            while !Task.isCancelled, ContinuousClock.now < deadline,
                  !(self.video.isPrimed && audio.isResident(segment)) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return }
            if !audio.isResident(segment) { self.logger.error("Audio segment \(segment) not ready; starting anyway") }
            self.outputLatency = AudioOutputLatency.current()
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: self.startLead, preferredTimescale: 1_000_000_000)
            audio.start(at: frame, anchorHostTime: Self.machTicks(host))
            let pictureDelay = self.outputLatency + self.avOffsetMs / 1000
            self.video.start(filmTime: filmTime, atHostTime: host + CMTime(seconds: pictureDelay, preferredTimescale: 1_000_000_000))
            self.rateSample = nil
            self.logger.info("Started at \(filmTime, format: .fixed(precision: 3))s (frame \(frame)), picture +\(pictureDelay * 1000, format: .fixed(precision: 0)) ms")
        }
    }

    private func frame(for filmTime: Double, in scene: AtmosScene) -> Int {
        max(0, Int(((filmTime - scene.startSeconds) * Double(scene.sampleRate)).rounded()))
    }

    private static func machTicks(_ time: CMTime) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(time.seconds * 1e9 * Double(info.denom) / Double(info.numer))
    }

    // MARK: Per-frame work (called by the stage)

    /// Current audio render frame (one buffer ahead of what is heard).
    public var currentFrame: Int { audio?.playhead.load(ordering: .relaxed) ?? 0 }

    /// An element's DAMF position and gain at `frame`, from the streamed
    /// segment holding it; a segment not yet fetched keeps the last state.
    public func state(of element: AtmosScene.Element, frame: Int) -> (pos: SIMD3<Float>, gainDB: Float) {
        if let audio, let streamer,
           let track = streamer.track(segment: frame / audio.segmentFrames, element: element.id) {
            let state = track.state(at: frame)
            lastState[element.id] = state
            return state
        }
        return lastState[element.id] ?? (SIMD3(0, 1, 0), -144)
    }

    /// Position relative to the listener's ears in metres: −z forward
    /// (toward the screen), +y up.
    public func listenerPosition(of element: AtmosScene.Element, frame: Int) -> SIMD3<Float> {
        let p = state(of: element, frame: frame).pos
        let z = flattenHeights ? 0 : max(0, min(p.z, 1))
        var local = SIMD3<Float>(p.x * roomHalfWidth, z * roomHeight, -p.y * roomHalfDepth)
        // A source at the listener's head has no direction; keep a minimum radius.
        let minRadius: Float = 0.6
        let length = simd_length(local)
        if length < minRadius {
            local = length > 0.001 ? local / length * minRadius : SIMD3(0, minRadius, 0)
        }
        return local
    }

    /// Pushes gains to the render side and refreshes telemetry. Called ~60 Hz.
    public func tick() {
        guard let audio, let scene else { return }
        let frame = currentFrame
        for element in scene.elements {
            let db = masterGainDB + state(of: element, frame: frame).gainDB + (element.isBed ? lfeGainDB : 0)
            audio.targetGain[element.channel] = db <= -120 ? 0 : powf(10, db / 20)
            let peak = audio.peak[element.channel]
            audio.peak[element.channel] = 0
            levels[element.channel] = max(peak, levels[element.channel] * 0.85)
        }

        let now = ContinuousClock.now
        guard now - lastTelemetry > .milliseconds(250) else { return }
        lastTelemetry = now
        let rendered = audio.renderedFrames.load(ordering: .relaxed)
        if isPlaying, let sample = rateSample {
            let seconds = Double((now - sample.time).components.attoseconds) / 1e18 + Double((now - sample.time).components.seconds)
            if seconds > 2 {
                measuredRate = Double(rendered - sample.frames) / seconds
                rateSample = (rendered, now)
            }
        } else if isPlaying {
            rateSample = (rendered, now)
        }
        var drift: Int64 = 0
        for ch in 0 ..< audio.channelCount { drift = max(drift, audio.maxDrift[ch]) }
        let resident = audio.slots.map { $0.segment.load(ordering: .relaxed) }.filter { $0 >= 0 }.sorted()
        clockReport = String(format: "%.0f Hz, max drift %d frames, segments %@, %d underrun buffers",
                             measuredRate, drift, resident.map(String.init).joined(separator: ","),
                             audio.underruns.load(ordering: .relaxed))
    }

    /// Audio position minus picture position, in ms, as each is currently
    /// scheduled to be perceived. Zero means in sync (given the offsets).
    public var scheduledSkewMs: Double? {
        guard let audio, let scene, isPlaying, audio.playing.load(ordering: .relaxed) else { return nil }
        let audioTime = scene.startSeconds + Double(audio.playhead.load(ordering: .relaxed)) / audio.sampleRate
        return (audioTime - outputLatency - avOffsetMs / 1000 - currentTime) * 1000
    }
}
