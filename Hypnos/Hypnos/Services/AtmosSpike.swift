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

 A scene can also stream from a Jellyfin server running the Atmos Objects
 plugin (`JellyfinPlugin/` at the repo root), which decodes a library item
 live from wherever playback is: its scene.json carries only the layout, and
 each fixed-length segment comes as FLAC files (channel groups of ≤8, FLAC's
 limit) plus an events file that opens with a snapshot of every element, so
 a segment stands alone. `AtmosSpikeStreamer` keeps the segments around the
 playhead in a small ring of slots with their tracks; the render callback
 finds the slot holding each frame's segment and plays silence (counted as
 an underrun) when it is not there yet.
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
    /// The whole timeline, for local scenes; streamed scenes serve events per segment.
    let events: [Event]?

    // Present only in scenes served by the Jellyfin plugin.
    let frameCount: Int?
    let segmentFrames: Int?
    let segmentCount: Int?
    /// Audio channels carried by each group's FLAC file, in file channel order.
    let groups: [[Int]]?
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

/// The PCM plus everything the render callbacks touch. Main thread writes
/// targets (gain, transport); render threads write telemetry (levels,
/// playhead). Plain-pointer fields are single-writer and read racily for
/// display only.
///
/// Samples live in slots, each holding one segment of interleaved Int16
/// frames for every channel. A local scene is a single slot over the mapped
/// file that loops; a streamed scene has a few owned slots that
/// `AtmosSpikeStreamer` refills as the playhead moves.
final class AtmosSpikeAudio: @unchecked Sendable {
    final class Slot: @unchecked Sendable {
        /// Segment index held, −1 while empty or being refilled. A writer
        /// stores −1 before touching `samples` and the new index after.
        let segment = Atomic<Int>(-1)
        let samples: UnsafeMutablePointer<Int16>
        private let owned: Bool

        init(samples: UnsafeMutablePointer<Int16>, owned: Bool) {
            self.samples = samples
            self.owned = owned
        }

        deinit {
            if owned { samples.deallocate() }
        }
    }

    let channelCount: Int
    let frameCount: Int
    let sampleRate: Double
    let segmentFrames: Int
    let slots: [Slot]
    /// Local clips loop; a streamed film plays silence past its end.
    private let loops: Bool
    private let mapping: Data?
    /// Channel-0 buffers that needed a segment no slot held.
    let underruns = Atomic<Int>(0)

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

    /// A local scene: the whole mapped file as one looping slot.
    convenience init(url: URL, channelCount: Int, sampleRate: Double) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= channelCount * 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let frames = data.count / (channelCount * 2)
        // Data backed by a mapping keeps its bytes at a stable address for its lifetime.
        let pointer = data.withUnsafeBytes { UnsafeMutableRawPointer(mutating: $0.baseAddress!).assumingMemoryBound(to: Int16.self) }
        let slot = Slot(samples: pointer, owned: false)
        slot.segment.store(0, ordering: .releasing)
        self.init(channelCount: channelCount, frameCount: frames, sampleRate: sampleRate,
                  segmentFrames: frames, slots: [slot], loops: true, mapping: data)
    }

    /// A streamed scene: `slotCount` empty segment slots for the streamer to fill.
    convenience init(channelCount: Int, frameCount: Int, sampleRate: Double, segmentFrames: Int, slotCount: Int) {
        let slots = (0..<slotCount).map { _ in
            let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: segmentFrames * channelCount)
            buffer.initialize(repeating: 0, count: segmentFrames * channelCount)
            return Slot(samples: buffer, owned: true)
        }
        self.init(channelCount: channelCount, frameCount: frameCount, sampleRate: sampleRate,
                  segmentFrames: segmentFrames, slots: slots, loops: false, mapping: nil)
    }

    private init(channelCount: Int, frameCount: Int, sampleRate: Double, segmentFrames: Int,
                 slots: [Slot], loops: Bool, mapping: Data?) {
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.segmentFrames = segmentFrames
        self.slots = slots
        self.loops = loops
        self.mapping = mapping

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

    /// Samples of the slot holding `segment`, if any.
    @inline(__always)
    func samples(forSegment segment: Int) -> UnsafePointer<Int16>? {
        for slot in slots where slot.segment.load(ordering: .acquiring) == segment {
            return UnsafePointer(slot.samples)
        }
        return nil
    }

    func isResident(_ segment: Int) -> Bool { samples(forSegment: segment) != nil }

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
        var cachedSegment = -1
        var cached: UnsafePointer<Int16>?
        var missing = false
        for i in 0..<n {
            var f = frame + i
            var value: Float = 0
            if f >= 0, loops { f %= total }
            if f >= 0, f < total {
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
            playhead.store(loops ? (frame + n) % total : min(frame + n, total), ordering: .relaxed)
            renderedFrames.add(n, ordering: .relaxed)
            if missing { underruns.add(1, ordering: .relaxed) }
        }
        isSilence.pointee = false
        return noErr
    }
}

// MARK: - Jellyfin source

/// Just enough of the Jellyfin API for the spike: item search and the Atmos
/// Objects plugin's endpoints. `server` includes any base URL path
/// (e.g. `https://host/jellyfin`).
struct AtmosSpikeJellyfin: Sendable {
    struct Item: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let productionYear: Int?

        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", productionYear = "ProductionYear"
        }
    }

    let server: URL
    let apiKey: String

    func search(_ term: String) async throws -> [Item] {
        struct Page: Decodable {
            let items: [Item]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        let page: Page = try await get("Items", query: [
            URLQueryItem(name: "searchTerm", value: term),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "25"),
        ])
        return page.items
    }

    func scene(_ itemId: String, startSeconds: Double) async throws -> Data {
        try await send(request("AtmosObjects/\(itemId)/Scene", query: [
            URLQueryItem(name: "startSeconds", value: String(format: "%.3f", startSeconds)),
        ]))
    }

    func segmentEvents(_ itemId: String, segment: Int) async throws -> [AtmosSpikeSceneFile.Event] {
        try await get("AtmosObjects/\(itemId)/Segments/\(segment)/Events")
    }

    func segment(_ itemId: String, segment: Int, group: Int) async throws -> Data {
        try await send(request("AtmosObjects/\(itemId)/Segments/\(segment)/\(group)"))
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(request(path, query: query)))
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var url = server.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("MediaBrowser Token=\"\(apiKey)\"", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(code) for \(request.url?.path(percentEncoded: false) ?? "?")",
            ])
        }
        return data
    }
}

/// Keeps the segments around the playhead decoded into the audio's slots:
/// one behind (a short back-seek stays instant) and `lookahead` ahead.
/// Fetches in playback order, one segment at a time, off the main actor. A
/// segment not yet decoded on the server is decoded on request, so the first
/// fetch after a long seek takes a second or two.
final class AtmosSpikeStreamer: Sendable {
    let audio: AtmosSpikeAudio
    let client: AtmosSpikeJellyfin
    let itemId: String
    let groups: [[Int]]
    let segmentCount: Int
    let lookahead = 3
    let fetched = Atomic<Int>(0)
    let failures = Atomic<Int>(0)
    /// Each resident segment's element tracks, by segment then element id.
    /// Written here, read by the main actor every tick.
    private let tracks = Mutex<[Int: [Int: AtmosSpikeTrack]]>([:])

    func track(segment: Int, element: Int) -> AtmosSpikeTrack? {
        tracks.withLock { $0[segment]?[element] }
    }

    init(audio: AtmosSpikeAudio, client: AtmosSpikeJellyfin, itemId: String, groups: [[Int]], segmentCount: Int) {
        self.audio = audio
        self.client = client
        self.itemId = itemId
        self.groups = groups
        self.segmentCount = segmentCount
    }

    func run() async {
        while !Task.isCancelled {
            let current = audio.playhead.load(ordering: .relaxed) / audio.segmentFrames
            let wanted = Array(max(0, current - 1)...min(segmentCount - 1, current + lookahead))
            // Nearest first: the playhead's segment, then ahead, then the one behind.
            let order = wanted.sorted { abs($0 - current) + ($0 < current ? 10 : 0) < abs($1 - current) + ($1 < current ? 10 : 0) }
            if let next = order.first(where: { !audio.isResident($0) }) {
                do {
                    try await load(next, keeping: Set(wanted))
                    fetched.add(1, ordering: .relaxed)
                } catch {
                    failures.add(1, ordering: .relaxed)
                    AppLogger.atmosSpike.error("Segment \(next) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func load(_ segment: Int, keeping wanted: Set<Int>) async throws {
        // Decode every group before claiming a slot, so the slot is only
        // unavailable for the copy itself.
        let events = try await client.segmentEvents(itemId, segment: segment)
        var decoded: [(channels: [Int], buffer: AVAudioPCMBuffer)] = []
        for (index, channels) in groups.enumerated() {
            let data = try await client.segment(itemId, segment: segment, group: index)
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
                for f in 0..<frames {
                    let v = max(-1, min(source[f], 32767.0 / 32768.0))
                    slot.samples[f * stride + channel] = Int16(v * 32768)
                }
                for f in frames..<capacity { slot.samples[f * stride + channel] = 0 }
            }
        }
        let byElement = Dictionary(grouping: events, by: \.id).mapValues { AtmosSpikeTrack(events: $0) }
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
        /// The whole timeline for a local scene; nil when streamed (see `state(of:frame:)`).
        let track: AtmosSpikeTrack?
    }

    // Library
    private(set) var availableScenes: [URL] = []
    private(set) var loadedScene: URL?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var elements: [Element] = []
    @ObservationIgnored private(set) var audio: AtmosSpikeAudio?

    // Jellyfin source
    var jellyfinServer: String = UserDefaults.standard.string(forKey: "atmosSpike.jellyfinServer") ?? "" {
        didSet { UserDefaults.standard.set(jellyfinServer, forKey: "atmosSpike.jellyfinServer") }
    }
    var jellyfinAPIKey: String = KeychainStore.string(for: .jellyfinAPIKey) ?? "" {
        didSet { KeychainStore.set(jellyfinAPIKey, for: .jellyfinAPIKey) }
    }
    private(set) var searchResults: [AtmosSpikeJellyfin.Item] = []
    /// What the Jellyfin load is doing ("Preparing 12:30 / 2:24:00"), nil when idle.
    private(set) var remoteStatus: String?
    /// Name of the streamed item currently loaded.
    private(set) var loadedRemoteName: String?
    private(set) var streamReport = ""
    @ObservationIgnored private var streamer: AtmosSpikeStreamer?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var lastStreamedState: [Int: (pos: SIMD3<Float>, gainDB: Float)] = [:]

    private var jellyfin: AtmosSpikeJellyfin? {
        let trimmed = jellyfinServer.trimmingCharacters(in: .whitespaces)
        guard !jellyfinAPIKey.isEmpty,
              let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              url.scheme != nil else { return nil }
        return AtmosSpikeJellyfin(server: url, apiKey: jellyfinAPIKey)
    }

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
        stopStreaming()
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

            install(file: file, audio: audio)
            loadedScene = directory
            loadedRemoteName = nil
            AppLogger.atmosSpike.info("Loaded \(directory.lastPathComponent, privacy: .public): \(file.elements.count) elements, \(file.events?.count ?? 0) events, \(self.durationSeconds, format: .fixed(precision: 1))s")
        } catch {
            loadError = error.localizedDescription
            AppLogger.atmosSpike.error("Load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func install(file: AtmosSpikeSceneFile, audio: AtmosSpikeAudio) {
        let byId = file.events.map { Dictionary(grouping: $0, by: \.id) }
        elements = file.elements.sorted { $0.channel < $1.channel }.map { element in
            Element(
                id: element.id,
                channel: element.channel,
                isBed: element.kind == "bed",
                bedChannel: element.bedChannel,
                track: byId.map { AtmosSpikeTrack(events: $0[element.id] ?? []) }
            )
        }
        self.audio = audio
        levels = Array(repeating: 0, count: elements.count)
        durationSeconds = Double(audio.frameCount) / audio.sampleRate
        positionSeconds = 0
    }

    // MARK: Jellyfin

    func searchJellyfin(_ term: String) async {
        guard let jellyfin else {
            loadError = "Set the Jellyfin server URL and API key first."
            return
        }
        do {
            searchResults = try await jellyfin.search(term)
            loadError = searchResults.isEmpty ? "No items match “\(term)”." : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Asks the plugin to prepare the item (extraction takes minutes for a
    /// film, the first time only), waits for it, then starts streaming.
    func loadJellyfin(_ item: AtmosSpikeJellyfin.Item) async {
        guard let jellyfin, !isLoading else { return }
        stop()
        stopStreaming()
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            remoteStatus = nil
        }
        do {
            // The server starts decoding from here if nothing is cached yet.
            remoteStatus = "Starting decode on server…"
            let json = try await jellyfin.scene(item.id, startSeconds: 0)
            let file = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(AtmosSpikeSceneFile.self, from: json)
            }.value
            guard let frameCount = file.frameCount, let segmentFrames = file.segmentFrames,
                  let segmentCount = file.segmentCount, let groups = file.groups else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let audio = AtmosSpikeAudio(channelCount: file.elements.count, frameCount: frameCount,
                                        sampleRate: Double(file.sampleRate), segmentFrames: segmentFrames, slotCount: 6)
            install(file: file, audio: audio)
            loadedScene = nil
            loadedRemoteName = item.name

            let streamer = AtmosSpikeStreamer(audio: audio, client: jellyfin, itemId: item.id,
                                              groups: groups, segmentCount: segmentCount)
            self.streamer = streamer
            streamTask = Task.detached(priority: .userInitiated) { await streamer.run() }
            // Have the first segment in hand before the space opens and play is offered.
            remoteStatus = "Buffering…"
            while !audio.isResident(0), streamer.failures.load(ordering: .relaxed) < 3 {
                try await Task.sleep(for: .milliseconds(100))
            }
            AppLogger.atmosSpike.info("Streaming \(item.name, privacy: .public): \(file.elements.count) elements, \(segmentCount) segments, groups \(groups.map(\.count), privacy: .public)")
        } catch {
            loadError = error.localizedDescription
            AppLogger.atmosSpike.error("Jellyfin load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        streamer = nil
        lastStreamedState = [:]
        streamReport = ""
    }

    /// An element's position and gain at `frame`: from the scene's own timeline
    /// when local, else from the streamed segment holding `frame`. A segment
    /// not yet fetched keeps the element where it was last seen.
    func state(of element: Element, frame: Int) -> (pos: SIMD3<Float>, gainDB: Float) {
        if let track = element.track { return track.state(at: frame) }
        if let audio, let streamer,
           let track = streamer.track(segment: frame / audio.segmentFrames, element: element.id) {
            let state = track.state(at: frame)
            lastStreamedState[element.id] = state
            return state
        }
        return lastStreamedState[element.id] ?? (SIMD3(0, 1, 0), -144)
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
        let p = state(of: element, frame: frame).pos
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
            let metaDB = state(of: element, frame: frame).gainDB
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

        if let streamer {
            let resident = audio.slots.map { $0.segment.load(ordering: .relaxed) }.filter { $0 >= 0 }.sorted()
            streamReport = "segments \(resident.map(String.init).joined(separator: ",")) resident, \(streamer.fetched.load(ordering: .relaxed)) fetched, \(streamer.failures.load(ordering: .relaxed)) failed, \(audio.underruns.load(ordering: .relaxed)) underrun buffers"
        }

        // Same readouts, for `build-and-sign --log` on device.
        if isPlaying, now - lastLog > .seconds(5) {
            lastLog = now
            AppLogger.atmosSpike.info("t=\(self.positionSeconds, format: .fixed(precision: 1))s rate=\(self.measuredRate, format: .fixed(precision: 0))Hz flatten=\(self.flattenHeights) \(self.clockReport, privacy: .public) \(self.streamReport, privacy: .public)")
        }
    }
}
#endif
