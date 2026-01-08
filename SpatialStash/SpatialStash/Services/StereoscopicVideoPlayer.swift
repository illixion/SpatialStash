/*
 Spatial Stash - Stereoscopic Video Player

 Coordinates downloading, converting, and playing stereoscopic 3D video.
 Downloads full video, converts to MV-HEVC, then plays the converted file.
 */

import AVFoundation
import Combine
import RealityKit

/// Player state for stereoscopic video
enum StereoscopicPlayerState: Equatable {
    case idle
    case downloading(progress: Double)
    case converting(progress: Double)
    case playing
    case paused
    case error(String)

    var isActive: Bool {
        switch self {
        case .downloading, .converting, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }
}

/// Reason for falling back to 2D playback
enum FallbackReason {
    case conversionFailed(Error)
    case downloadFailed(Error)
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
    private(set) var avPlayer: AVPlayer?

    // Components
    private let converter = MVHEVCConverter()
    private let videoCache = DiskVideoCache.shared

    // State
    private var currentVideo: GalleryVideo?
    private var apiKey: String?
    @Published private(set) var convertedFileURL: URL?
    private var isUsingCachedVideo: Bool = false

    // Tasks
    private var processingTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?

    init() {}

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
        isUsingCachedVideo = false

        let formatString = format.rawValue

        processingTask = Task {
            do {
                // Check cache first
                if let cachedURL = await videoCache.getCachedVideoURL(videoId: video.stashId, format: formatString) {
                    // Cache hit! Use cached converted video
                    print("[StereoscopicPlayer] Cache hit for video: \(video.stashId)")

                    await MainActor.run {
                        self.currentChunkInfo = "Loading from cache..."
                        self.isUsingCachedVideo = true
                    }

                    // Get duration from cached file
                    let asset = AVURLAsset(url: cachedURL)
                    let durationCM = try await asset.load(.duration)
                    await MainActor.run {
                        self.duration = durationCM.seconds
                        self.convertedFileURL = cachedURL
                        self.startPlayback(url: cachedURL)
                    }
                    return
                }

                // Cache miss - need to download and convert
                print("[StereoscopicPlayer] Cache miss for video: \(video.stashId), downloading...")

                await MainActor.run {
                    self.state = .downloading(progress: 0)
                    self.currentChunkInfo = "Downloading video..."
                }

                // Step 1: Download the complete video
                let localVideoURL = try await downloadVideo(video: video, apiKey: apiKey)

                if Task.isCancelled { return }

                // Step 2: Get video duration
                let asset = AVURLAsset(url: localVideoURL)
                let durationCM = try await asset.load(.duration)
                let videoDuration = durationCM.seconds
                await MainActor.run {
                    self.duration = videoDuration
                }

                // Step 3: Convert to MV-HEVC
                await MainActor.run {
                    self.state = .converting(progress: 0)
                    self.currentChunkInfo = "Converting to 3D..."
                }

                let config = MVHEVCConversionConfig.from(video: video, format: format)
                let convertedURL = try await converter.convertFullVideo(
                    sourceURL: localVideoURL,
                    config: config,
                    videoId: video.stashId,
                    progressHandler: { progress in
                        Task { @MainActor in
                            self.state = .converting(progress: progress)
                            self.currentChunkInfo = "Converting: \(Int(progress * 100))%"
                        }
                    }
                )

                if Task.isCancelled { return }

                // Clean up downloaded source file
                try? FileManager.default.removeItem(at: localVideoURL)

                // Step 4: Cache the converted video
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: convertedURL.path)
                let fileSize = (fileAttributes?[.size] as? Int64) ?? 0

                let metadata = CachedVideoMetadata(
                    videoId: video.stashId,
                    originalURL: video.streamURL.absoluteString,
                    stereoscopicFormat: formatString,
                    sourceWidth: video.sourceWidth ?? 0,
                    sourceHeight: video.sourceHeight ?? 0,
                    duration: videoDuration,
                    fileSize: fileSize,
                    cachedDate: Date()
                )

                // Move converted file to cache (more efficient than copy)
                let cachedURL = try await videoCache.moveVideoToCache(
                    from: convertedURL,
                    videoId: video.stashId,
                    format: formatString,
                    metadata: metadata
                )

                if Task.isCancelled { return }

                // Step 5: Start playback from cached location
                await MainActor.run {
                    self.convertedFileURL = cachedURL
                    self.isUsingCachedVideo = true
                    self.startPlayback(url: cachedURL)
                }

            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    self.postFallbackNotification(reason: .conversionFailed(error))
                }
            }
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

    /// Seek to a time in seconds
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
    }

    /// Seek to a percentage of the video
    func seek(toPercentage percentage: Double) {
        let targetTime = duration * percentage
        seek(to: targetTime)
    }

    /// Stop playback and cleanup
    func stop() {
        processingTask?.cancel()
        processingTask = nil

        downloadTask?.cancel()
        downloadTask = nil
        downloadObservation?.invalidate()
        downloadObservation = nil

        if let observer = timeObserver, let player = avPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        avPlayer?.pause()
        avPlayer = nil

        // Only clean up converted file if it's NOT from cache
        // Cached files should persist for future playback
        if !isUsingCachedVideo, let url = convertedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        convertedFileURL = nil

        // Clean up any temp files from converter (not the cache)
        if let video = currentVideo {
            Task {
                await converter.cleanup(videoId: video.stashId)
            }
        }

        currentVideo = nil
        isUsingCachedVideo = false
        state = .idle
        currentTime = 0
        duration = 0
        bufferProgress = 0
        currentChunkInfo = ""
    }

    /// Request fallback to 2D playback
    func requestFallback(reason: FallbackReason = .userRequested) {
        guard let video = currentVideo else { return }
        stop()
        postFallbackNotification(reason: reason, video: video)
    }

    // MARK: - Private Methods

    private func downloadVideo(video: GalleryVideo, apiKey: String?) async throws -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let downloadDir = cachesDir.appendingPathComponent("StereoscopicDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let destinationURL = downloadDir.appendingPathComponent("\(video.stashId)_source.mp4")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)

        var request = URLRequest(url: video.streamURL)
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession.shared
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let tempURL = tempURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(throwing: URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned status \(statusCode)"
                    ]))
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            // Observe download progress
            self.downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress.fractionCompleted)
                    self?.currentChunkInfo = "Downloading: \(Int(progress.fractionCompleted * 100))%"
                }
            }

            self.downloadTask = task
            task.resume()
        }
    }

    private func startPlayback(url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)

        // Enable looping
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        self.avPlayer = player

        // Setup time observer
        setupTimeObserver()

        // Start playback
        player.play()
        state = .playing
        currentChunkInfo = "Playing"

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
            self.currentTime = time.seconds
        }
    }

    private func postFallbackNotification(reason: FallbackReason, video: GalleryVideo? = nil) {
        let videoToUse = video ?? currentVideo
        guard let video = videoToUse else { return }

        NotificationCenter.default.post(
            name: .stereoscopicFallbackTo2D,
            object: self,
            userInfo: ["reason": reason, "video": video]
        )
    }
}

// MARK: - Errors

enum StereoscopicPlayerError: Error, LocalizedError {
    case notStereoscopic
    case downloadFailed(String)
    case conversionFailed(String)
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notStereoscopic:
            return "Video is not stereoscopic"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .conversionFailed(let msg):
            return "Conversion failed: \(msg)"
        case .playbackFailed(let msg):
            return "Playback failed: \(msg)"
        }
    }
}
