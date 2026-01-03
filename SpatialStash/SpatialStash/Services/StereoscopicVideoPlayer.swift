/*
 Spatial Stash - Stereoscopic Video Player

 Coordinates downloading, converting, buffering, and playing stereoscopic 3D video.
 Orchestrates the full pipeline from SBS/OU source to MV-HEVC playback.
 */

import AVFoundation
import Combine
import RealityKit

/// Player state for stereoscopic video
enum StereoscopicPlayerState: Equatable {
    case idle
    case loading
    case buffering(progress: Double)
    case playing
    case paused
    case error(String)

    var isActive: Bool {
        switch self {
        case .loading, .buffering, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }
}

/// Reason for falling back to 2D playback
enum FallbackReason {
    case conversionFailed(Error)
    case insufficientResources
    case unsupportedFormat
    case userRequested
}

/// Notification names for stereoscopic player events
extension Notification.Name {
    static let stereoscopicFallbackTo2D = Notification.Name("stereoscopicFallbackTo2D")
    static let stereoscopicPlaybackReady = Notification.Name("stereoscopicPlaybackReady")
}

/// Main coordinator for stereoscopic video playback
@MainActor
class StereoscopicVideoPlayer: ObservableObject {
    // Published state
    @Published private(set) var state: StereoscopicPlayerState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var bufferProgress: Double = 0
    @Published private(set) var currentChunkInfo: String = ""

    // AVPlayer for playback
    private(set) var avPlayer: AVQueuePlayer?

    // Components
    private let downloader = VideoChunkDownloader()
    private let converter = MVHEVCConverter()
    private let bufferManager = ChunkBufferManager()

    // State
    private var currentVideo: GalleryVideo?
    private var apiKey: String?
    private var videoInfo: VideoStreamInfo?
    private var conversionConfig: MVHEVCConversionConfig?

    // Tasks
    private var downloadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var itemEndObservation: NSObjectProtocol?

    // Error tracking
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    init() {
        setupObservers()
    }

    deinit {
        // Note: stop() must be called from MainActor context before deinit
    }

    // MARK: - Public API

    /// Start playing a stereoscopic video
    /// - Parameters:
    ///   - video: The video to play
    ///   - apiKey: Optional API key for authentication
    func play(video: GalleryVideo, apiKey: String?) async {
        guard video.isStereoscopic,
              let format = video.stereoscopicFormat else {
            state = .error("Video is not stereoscopic")
            return
        }

        // Stop any existing playback
        stop()

        currentVideo = video
        self.apiKey = apiKey
        state = .loading
        consecutiveFailures = 0

        do {
            // Probe video for stream info
            videoInfo = try await downloader.probeVideo(url: video.streamURL, apiKey: apiKey)

            guard let videoInfo = videoInfo else {
                throw StereoscopicPlayerError.probeFailure
            }

            duration = videoInfo.totalDuration
            let totalChunks = await downloader.totalChunks(for: videoInfo)

            // Create conversion config
            conversionConfig = MVHEVCConversionConfig.from(
                video: video,
                format: format
            )

            // Configure buffer
            await bufferManager.configure(totalChunks: totalChunks, looping: true)

            // Start download and conversion pipeline
            downloadTask = Task {
                await downloadAndConvertLoop()
            }

            // Wait for initial buffer
            await waitForInitialBuffer()

            // Start playback
            await startPlayback()

        } catch {
            state = .error(error.localizedDescription)
            NotificationCenter.default.post(
                name: .stereoscopicFallbackTo2D,
                object: self,
                userInfo: ["reason": FallbackReason.conversionFailed(error), "video": video]
            )
        }
    }

    /// Pause playback
    func pause() {
        avPlayer?.pause()
        state = .paused
    }

    /// Resume playback
    func resume() {
        avPlayer?.play()
        state = .playing
    }

    /// Toggle play/pause
    func togglePlayPause() {
        if state == .playing {
            pause()
        } else if state == .paused {
            resume()
        }
    }

    /// Seek to a percentage of the video
    func seek(toPercentage percentage: Double) async {
        await bufferManager.seek(toPercentage: percentage)
        // Rebuild the player queue from the new position
        await rebuildPlayerQueue()
    }

    /// Stop playback and cleanup
    func stop() {
        downloadTask?.cancel()
        downloadTask = nil

        if let observer = timeObserver, let player = avPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        avPlayer?.pause()
        avPlayer?.removeAllItems()
        avPlayer = nil

        Task {
            await bufferManager.clear()
            if let video = currentVideo {
                await converter.cleanup(videoId: video.stashId)
            }
        }

        if let observation = itemEndObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        itemEndObservation = nil

        currentVideo = nil
        videoInfo = nil
        conversionConfig = nil
        state = .idle
        currentTime = 0
        duration = 0
        bufferProgress = 0
        consecutiveFailures = 0
    }

    /// Request fallback to 2D playback
    func requestFallback(reason: FallbackReason = .userRequested) {
        guard let video = currentVideo else { return }

        stop()

        NotificationCenter.default.post(
            name: .stereoscopicFallbackTo2D,
            object: self,
            userInfo: ["reason": reason, "video": video]
        )
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observers are set up during playback initialization
    }

    private func updateBufferState() async {
        let bufferState = await bufferManager.state
        switch bufferState {
        case .buffering(let progress):
            bufferProgress = progress
            // Only update state if we're not already playing
            if state != .playing && state != .paused {
                state = .buffering(progress: progress)
            }
        case .ready:
            bufferProgress = 1.0
        case .error(let message):
            state = .error(message)
        default:
            break
        }
    }

    private func downloadAndConvertLoop() async {
        guard let video = currentVideo,
              let videoInfo = videoInfo,
              let config = conversionConfig else {
            return
        }

        while !Task.isCancelled {
            let neededChunks = await bufferManager.chunksNeeded()

            if neededChunks.isEmpty {
                // Buffer is full, wait before checking again
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            for chunkIndex in neededChunks {
                guard !Task.isCancelled else { return }

                do {
                    // Download chunk
                    let chunk = try await downloader.downloadChunk(
                        url: video.streamURL,
                        apiKey: apiKey,
                        chunkIndex: chunkIndex,
                        videoInfo: videoInfo
                    )

                    // Convert to MV-HEVC
                    let converted = try await converter.convert(
                        chunkData: chunk.data,
                        chunkIndex: chunkIndex,
                        config: config,
                        videoId: video.stashId
                    )

                    // Add to buffer
                    await bufferManager.addChunk(converted, isLast: chunk.isLast)

                    // Update buffer state on main actor
                    await MainActor.run {
                        Task {
                            await self.updateBufferState()
                            let stats = await self.bufferManager.bufferStats()
                            self.currentChunkInfo = "Chunk \(stats.current + 1)/\(stats.total)"
                        }
                    }

                    // Reset failure counter on success
                    consecutiveFailures = 0

                    // Queue the chunk for playback if player is ready
                    await queueChunkIfReady(converted)

                } catch {
                    print("[StereoscopicPlayer] Chunk \(chunkIndex) failed: \(error)")
                    consecutiveFailures += 1

                    if consecutiveFailures >= maxConsecutiveFailures {
                        await MainActor.run {
                            requestFallback(reason: .conversionFailed(error))
                        }
                        return
                    }
                }
            }
        }
    }

    private func waitForInitialBuffer() async {
        // Wait until buffer is ready to play
        var attempts = 0
        let maxAttempts = 300 // 30 seconds max wait

        while await !bufferManager.isReadyToPlay && attempts < maxAttempts {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1

            if Task.isCancelled { return }
        }

        if attempts >= maxAttempts {
            state = .error("Timeout waiting for initial buffer")
        }
    }

    private func startPlayback() async {
        guard let firstChunk = await bufferManager.getCurrentChunk() else {
            state = .error("No chunks available for playback")
            return
        }

        // Create queue player
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        self.avPlayer = player

        // Add initial items to queue
        let firstItem = bufferManager.createPlayerItem(for: firstChunk)
        player.insert(firstItem, after: nil)

        // Try to queue the next chunk too
        if let nextChunk = await bufferManager.peekNextChunk() {
            let nextItem = bufferManager.createPlayerItem(for: nextChunk)
            player.insert(nextItem, after: firstItem)
        }

        // Setup time observer
        setupTimeObserver()

        // Setup item end observer
        setupItemEndObserver()

        // Start playback
        player.play()
        state = .playing

        NotificationCenter.default.post(
            name: .stereoscopicPlaybackReady,
            object: self,
            userInfo: ["player": player]
        )
    }

    private func setupTimeObserver() {
        guard let player = avPlayer else { return }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            // Calculate total time based on chunk position + current item time
            Task { @MainActor in
                let chunkIndex = await self.bufferManager.currentIndex
                let chunkDuration = 20.0 // Approximate chunk duration
                self.currentTime = (Double(chunkIndex) * chunkDuration) + time.seconds
            }
        }
    }

    private func setupItemEndObserver() {
        itemEndObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let item = notification.object as? AVPlayerItem,
                  self.avPlayer?.items().contains(item) == true else {
                return
            }

            Task { @MainActor in
                await self.handleChunkTransition()
            }
        }
    }

    private func handleChunkTransition() async {
        // Advance to next chunk in buffer
        guard let nextChunk = await bufferManager.advanceToNextChunk() else {
            // No more chunks and not looping
            state = .paused
            return
        }

        // Queue the following chunk
        if let followingChunk = await bufferManager.peekNextChunk() {
            let item = bufferManager.createPlayerItem(for: followingChunk)
            avPlayer?.insert(item, after: avPlayer?.items().last)
        }
    }

    private func queueChunkIfReady(_ chunk: ConvertedChunk) async {
        guard let player = avPlayer, state == .playing || state == .paused else {
            return
        }

        // Only queue if this is the next expected chunk
        let currentIndex = await bufferManager.currentIndex
        let chunkCount = await bufferManager.chunkCount
        let nextExpectedIndex = (currentIndex + player.items().count) % chunkCount

        if chunk.index == nextExpectedIndex {
            let bufferedChunk = BufferedChunk(
                index: chunk.index,
                fileURL: chunk.fileURL,
                duration: chunk.duration,
                isLast: chunk.isLast
            )
            let item = bufferManager.createPlayerItem(for: bufferedChunk)
            player.insert(item, after: player.items().last)
        }
    }

    private func rebuildPlayerQueue() async {
        guard let player = avPlayer else { return }

        // Remove all items except current
        while player.items().count > 1 {
            if let lastItem = player.items().last {
                player.remove(lastItem)
            }
        }

        // Queue next chunks from new position
        if let currentChunk = await bufferManager.getCurrentChunk() {
            let item = bufferManager.createPlayerItem(for: currentChunk)
            player.replaceCurrentItem(with: item)
        }

        if let nextChunk = await bufferManager.peekNextChunk() {
            let item = bufferManager.createPlayerItem(for: nextChunk)
            player.insert(item, after: player.currentItem)
        }
    }
}

// MARK: - Errors

enum StereoscopicPlayerError: Error, LocalizedError {
    case notStereoscopic
    case probeFailure
    case noChunksAvailable
    case playbackFailed(String)
    case conversionTimeout

    var errorDescription: String? {
        switch self {
        case .notStereoscopic:
            return "Video is not stereoscopic"
        case .probeFailure:
            return "Failed to probe video stream"
        case .noChunksAvailable:
            return "No chunks available for playback"
        case .playbackFailed(let msg):
            return "Playback failed: \(msg)"
        case .conversionTimeout:
            return "Conversion timed out"
        }
    }
}
