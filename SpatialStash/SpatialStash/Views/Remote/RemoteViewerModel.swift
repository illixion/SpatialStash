/*
 Spatial Stash - Remote Viewer Model

 Core slideshow engine for the Remote API Viewer. Manages image fetching,
 prefetching, timer-driven transitions, Ken Burns focus points, dynamic
 brightness, WebSocket integration, and navigation state.
 */

import CoreGraphics
import os
import SwiftUI
import UIKit

@MainActor
@Observable
class RemoteViewerModel {
    // MARK: - Configuration

    var config: RemoteViewerConfig

    // MARK: - Gallery Mode

    /// When set, the viewer pulls images from the app's gallery instead of the remote API.
    /// Tag lists, blocked posts, WS, and API features are disabled in this mode.
    var galleryImageSource: (any ImageSource)?
    var isGalleryMode: Bool { galleryImageSource != nil }
    /// Filter criteria to apply when fetching gallery images (respects app's current filter)
    var galleryFilter: ImageFilterCriteria?
    private var galleryPage: Int = 0

    // MARK: - Media Type

    /// The type of media currently being displayed
    enum SlideshowMediaType: Equatable {
        case image
        case video(URL)      // Video URL to play in WebVideoPlayerView
        case animatedGIF(URL) // HEVC-converted GIF URL
    }

    /// Current media type (image, video, or animated GIF)
    var currentMediaType: SlideshowMediaType = .image
    /// True when the current post is an animated GIF (even while showing static first frame during conversion)
    var isCurrentPostAnimatedGIF: Bool = false
    /// Whether the viewer window is in the user's current room (for video lifecycle)
    var isRoomActive: Bool = true

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    // MARK: - Display State

    var currentImage: UIImage?
    var nextImage: UIImage?
    var currentPost: RemotePost?
    var nextPost: RemotePost?
    var isTransitioning: Bool = false
    var isLoading: Bool = false
    var isPaused: Bool = false
    var enableDisplaySync: Bool = false
    var showClock: Bool = true
    var showSensors: Bool = true

    // Toast notifications
    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // Save grace period — keeps previous post saveable for 1.5s after transition
    private var previousPost: RemotePost?
    private var previousPostGraceTask: Task<Void, Never>?

    /// The post that the save button should act on (current, or previous during grace period)
    var saveablePost: RemotePost? {
        currentPost ?? previousPost
    }

    // Ken Burns
    var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Dynamic brightness (auto-computed from image luminance)
    var autoBrightnessAdjustment: Double = 0
    var autoContrastAdjustment: Double = 1.0

    // User visual adjustments (per-viewer session)
    var currentAdjustments: VisualAdjustments = VisualAdjustments()
    var showAdjustmentsPopover: Bool = false

    /// Effective brightness combines auto + user + global adjustments
    var effectiveBrightness: Double {
        autoBrightnessAdjustment + currentAdjustments.brightness + globalAdjustments.brightness
    }

    var effectiveContrast: Double {
        autoContrastAdjustment * currentAdjustments.contrast * globalAdjustments.contrast
    }

    var effectiveSaturation: Double {
        currentAdjustments.saturation * globalAdjustments.saturation
    }

    var effectiveOpacity: Double {
        currentAdjustments.opacity * globalAdjustments.opacity
    }

    /// Reference to global adjustments from AppModel
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

    // MARK: - Content State

    var cachedPosts: [RemotePost] = []
    var postHistory: [RemotePost] = []
    var historyImageURLs: [Int: URL] = [:]
    var currentTagListIndex: Int = 0
    var dbCursor: String?
    var isFetching: Bool = false
    var fetchReturnedEmpty: Bool = false

    // MARK: - Blocking (merged from server + local config)

    var blockedPosts: Set<Int> = []
    var blockedTags: Set<String> = []

    // MARK: - Sensor Display

    var sortedSensors: [HASensorReading] {
        wsClient.sensorData.values.sorted { $0.friendlyName < $1.friendlyName }
    }

    // MARK: - Window Callbacks

    var onOpenVideoWindow: ((URL) -> Void)?
    var onDismissVideoWindow: (() -> Void)?
    var onOpenAlertWindow: ((String, String, String?) -> Void)?
    var onDismissAlertWindow: (() -> Void)?

    // MARK: - Services

    let apiClient = RemoteAPIClient()
    let wsClient = RemoteWebSocketClient()

    /// Max dimension for downsampling loaded images (0 = no limit)
    var maxImageResolution: Int = 0

    // MARK: - Private

    private var gifConversionTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var backgroundUnloadTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var lastAdvanceTime: Date?
    private static let backgroundUnloadDelay: TimeInterval = 30
    private static let watchdogInterval: TimeInterval = 10
    private var windowAspectRatio: Double = 16.0 / 9.0

    /// Pre-downloaded images ready for instant display
    private var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL)] = []
    private static let prefetchTarget = 3

    // MARK: - Init

    init(config: RemoteViewerConfig) {
        self.config = config
        self.showClock = config.showClock
        self.showSensors = config.showSensors
        // Use configured default list, or last active list (persisted for "Server Decides"
        // recovery on relaunch), falling back to 0
        self.currentTagListIndex = config.defaultTagListIndex ?? config.lastActiveTagListIndex ?? 0

        // Initialize blocked lists from config
        self.blockedPosts = Set(config.blockedPosts)
        self.blockedTags = Set(config.blockedTags)
    }

    /// Callback to persist config changes back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    /// Persist the active tag list index so "Server Decides" mode can recover it on relaunch
    private func persistActiveTagList() {
        config.lastActiveTagListIndex = currentTagListIndex
        onConfigChanged?(config)
    }

    // MARK: - Lifecycle

    func start() {
        if !isGalleryMode {
            // Randomize cursor on initial load so we don't always start at the same position
            if dbCursor == nil {
                dbCursor = String(Double.random(in: 0..<1))
            }
            setupWebSocket()

            // If "Server Decides" is configured and WS is active, wait 1s for the
            // server to send a currentTagList message before starting the slideshow
            if config.defaultTagListIndex == nil && !config.wsEndpoint.isEmpty {
                slideshowTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.slideshowTask = nil
                    self?.startSlideshow()
                }
                startWatchdog()
                return
            }
        }
        startSlideshow()
        startWatchdog()
    }

    func stop() {
        slideshowTask?.cancel()
        slideshowTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        gifConversionTask?.cancel()
        gifConversionTask = nil
        backgroundUnloadTask?.cancel()
        backgroundUnloadTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        wsClient.disconnect()
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            // Returning to active
            wsClient.sendVisibilityChange(visible: true)
            isRoomActive = true
            backgroundUnloadTask?.cancel()
            backgroundUnloadTask = nil

            let wasBackgrounded = backgroundedAt
            backgroundedAt = nil

            if !isPaused {
                // If backgrounded > 30s, image was unloaded — advance to next
                if let wasBackgrounded,
                   Date().timeIntervalSince(wasBackgrounded) >= Self.backgroundUnloadDelay {
                    goToNextImage()
                }
                startSlideshow()
            }
        } else if oldPhase == .active && newPhase != .active {
            // Entering background — pause slideshow, schedule image/video unload
            wsClient.sendVisibilityChange(visible: false)
            isRoomActive = false
            slideshowTask?.cancel()
            slideshowTask = nil
            backgroundedAt = Date()

            backgroundUnloadTask = Task {
                try? await Task.sleep(for: .seconds(Self.backgroundUnloadDelay))
                guard !Task.isCancelled else { return }
                // Unload images and video state to free memory
                currentImage = nil
                nextImage = nil
                currentMediaType = .image
                prefetchedImages.removeAll()
                gifConversionTask?.cancel()
                gifConversionTask = nil
                AppLogger.remoteViewer.info("Background unload: released images/video after 30s")
            }
        }
    }

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
    }

    // MARK: - Navigation

    func goToNextImage() {
        // Restart the slideshow timer with an immediate advance
        slideshowTask?.cancel()
        slideshowTask = Task { [weak self] in
            guard let self else { return }
            await advanceToNextImage()
            while !Task.isCancelled {
                let delay = effectiveDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await advanceToNextImage()
            }
        }
    }

    func previousImage() {
        guard postHistory.count >= 2 else { return }
        // Move current to cache front, go back in history
        if let current = currentPost {
            cachedPosts.insert(current, at: 0)
        }
        postHistory.removeLast() // remove current
        let previous = postHistory.last!

        Task {
            await fetchAndDisplayPost(previous)
        }
    }

    func jumpToHistoryPost(_ post: RemotePost) {
        // Restart the slideshow timer with the selected post displayed immediately
        slideshowTask?.cancel()
        slideshowTask = Task { [weak self] in
            guard let self else { return }
            await fetchAndDisplayPost(post)
            while !Task.isCancelled {
                let delay = effectiveDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await advanceToNextImage()
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            slideshowTask?.cancel()
            slideshowTask = nil
        } else {
            startSlideshow()
        }
    }

    func saveCurrentPost() {
        guard let post = saveablePost else { return }
        Task {
            do {
                let result = try await apiClient.save(baseURL: config.apiEndpoint, postId: post._id)
                AppLogger.remoteViewer.info("Saved post \(post._id, privacy: .public): \(result, privacy: .public)")
                showToast(result)
            } catch {
                AppLogger.remoteViewer.error("Failed to save post: \(error.localizedDescription, privacy: .public)")
                showToast("Save failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func blockCurrentPost() {
        guard let post = currentPost else { return }
        blockedPosts.insert(post._id)
        config.blockedPosts = Array(blockedPosts)
        wsClient.sendBlock(postId: post._id)
        onConfigChanged?(config)
        showToast("Blocked post #\(post._id)")
        goToNextImage()
    }

    func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastIsError = isError
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    func switchToTagList(_ index: Int) {
        guard index < config.tagLists.count, index != currentTagListIndex else { return }
        currentTagListIndex = index
        persistActiveTagList()
        fetchReturnedEmpty = false
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        prefetchTask?.cancel()
        dbCursor = String(Double.random(in: 0..<1))
        let firstTag = config.tagLists[index].first ?? ""
        showToast("List \(index + 1)/\(config.tagLists.count): \(firstTag)")
        goToNextImage()
    }

    func cycleTagList() {
        guard !config.tagLists.isEmpty else { return }
        currentTagListIndex = (currentTagListIndex + 1) % config.tagLists.count
        persistActiveTagList()
        // Clear all caches so the server is re-queried with the new tags
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        prefetchTask?.cancel()
        dbCursor = String(Double.random(in: 0..<1))
        // Show list number and first tag
        let firstTag = config.tagLists[currentTagListIndex].first ?? ""
        showToast("List \(currentTagListIndex + 1)/\(config.tagLists.count): \(firstTag)")
        goToNextImage()
    }

    func toggleClock() {
        showClock.toggle()
    }

    func toggleSensors() {
        showSensors.toggle()
    }

    // MARK: - Private: Slideshow

    private func startSlideshow() {
        // Don't restart if already running
        guard slideshowTask == nil else { return }
        slideshowTask = Task { [weak self] in
            guard let self else { return }

            // Initial load
            if currentImage == nil && currentMediaType == .image {
                await advanceToNextImage()
            }

            while !Task.isCancelled {
                let delay = effectiveDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await advanceToNextImage()
            }
            // Note: do NOT set slideshowTask = nil here. When this task is cancelled,
            // the caller (goToNextImage, togglePause, handleScenePhaseChange, etc.)
            // has already set slideshowTask to either a new task or nil. Setting it
            // here would race with and overwrite the replacement task reference.
        }
    }

    /// Effective delay for the current post — uses video duration if available and longer than config delay
    private var effectiveDelay: TimeInterval {
        if case .video = currentMediaType,
           let duration = currentPost?.duration, duration > config.delay {
            return duration
        }
        return config.delay
    }

    /// Periodic watchdog that detects a stuck slideshow and restarts it.
    /// Checks every 10 seconds whether an advance has happened within the expected
    /// window (delay + 30s margin for network/processing). Only acts when the
    /// slideshow should be running (not paused, not backgrounded).
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard !Task.isCancelled else { break }

                // Only intervene when the slideshow should be actively running
                guard !isPaused, backgroundedAt == nil else { continue }

                let maxExpected = effectiveDelay + 30
                if let last = lastAdvanceTime {
                    let elapsed = Date().timeIntervalSince(last)
                    if elapsed > maxExpected {
                        AppLogger.remoteViewer.warning("Watchdog: slideshow stuck (\(Int(elapsed))s since last advance, expected ≤\(Int(maxExpected))s). Restarting.")
                        slideshowTask?.cancel()
                        slideshowTask = nil
                        startSlideshow()
                    }
                } else if slideshowTask == nil {
                    // No advance ever happened and no task is running
                    AppLogger.remoteViewer.warning("Watchdog: no slideshow task running. Starting.")
                    startSlideshow()
                }
            }
        }
    }

    private func advanceToNextImage() async {
        // Use a prefetched image if available for instant transition
        if let prefetched = prefetchedImages.first {
            prefetchedImages.removeFirst()
            guard !Task.isCancelled else { return }
            isCurrentPostAnimatedGIF = false
            await displayImage(prefetched.image, post: prefetched.post, url: prefetched.url)
            triggerPrefetch()
            return
        }

        // Ensure we have posts — wait for any in-flight fetch to finish
        await ensurePostsAvailable()
        guard !Task.isCancelled else { return }

        guard let post = nextNonBlockedPost() else {
            AppLogger.remoteViewer.warning("No posts available")
            fetchReturnedEmpty = true
            return
        }

        await fetchAndDisplayPost(post)
        triggerPrefetch()
    }

    /// Wait until cached posts are available, fetching if needed.
    /// If a fetch is already in flight, polls until it completes (with timeout).
    private func ensurePostsAvailable() async {
        if !cachedPosts.isEmpty { return }

        if !isFetching {
            await fetchMorePosts()
        }

        // Wait for an in-flight fetch to finish, with a 10-second timeout
        // to avoid spinning indefinitely if the fetch fails silently
        var waitIterations = 0
        while isFetching && cachedPosts.isEmpty && waitIterations < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            waitIterations += 1
        }
    }

    /// Pop the next non-blocked post from the cached posts queue
    private func nextNonBlockedPost() -> RemotePost? {
        while !cachedPosts.isEmpty {
            let candidate = cachedPosts.removeFirst()
            if !blockedPosts.contains(candidate._id) &&
               !candidate.tags.contains(where: { blockedTags.contains($0) }) {
                return candidate
            }
        }
        return nil
    }

    /// Download and display a single post (slow path, no prefetch available).
    /// Detects video and animated GIF content for appropriate playback.
    private func fetchAndDisplayPost(_ post: RemotePost) async {
        isLoading = true
        defer { isLoading = false }

        guard let imageURL = resolveImageURL(for: post) else { return }

        let ext = post.file_ext.lowercased()

        // Video posts: display directly via WebVideoPlayerView without downloading
        if Self.videoExtensions.contains(ext) {
            guard !Task.isCancelled else { return }
            await displayVideo(url: imageURL, post: post)
            return
        }

        // Download in a detached task so it isn't cancelled by slideshow task replacement
        let maxRes = maxImageResolution
        let downloadResult: (image: UIImage, data: Data)? = await Task.detached {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                if maxRes > 0 {
                    let maxDim = CGFloat(maxRes)
                    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                    if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) {
                        let downsampleOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxDim,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) {
                            return (UIImage(cgImage: cgImage), data)
                        }
                    }
                }
                if let image = UIImage(data: data) {
                    return (image, data)
                }
                return nil
            } catch {
                AppLogger.remoteViewer.error("Failed to load post \(post._id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value

        guard let result = downloadResult else { return }
        guard !Task.isCancelled else { return }

        // Animated GIF: show first frame immediately, convert to HEVC in background
        if ext == "gif" && result.data.isAnimatedGIF {
            isCurrentPostAnimatedGIF = true
            await displayImage(result.image, post: post, url: imageURL, mediaType: .image)
            // Start HEVC conversion in background — swap to video playback when ready
            let data = result.data
            gifConversionTask?.cancel()
            gifConversionTask = Task { [weak self] in
                do {
                    let hevcURL = try await GIFHEVCConverter.shared.convert(gifData: data, sourceURL: imageURL)
                    guard !Task.isCancelled else { return }
                    // Only swap if we're still showing this post
                    if self?.currentPost?._id == post._id {
                        self?.currentMediaType = .animatedGIF(hevcURL)
                        AppLogger.remoteViewer.info("GIF HEVC ready for post \(post._id, privacy: .public)")
                    }
                } catch {
                    AppLogger.remoteViewer.warning("GIF HEVC conversion failed for post \(post._id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        isCurrentPostAnimatedGIF = false
        await displayImage(result.image, post: post, url: imageURL)
    }

    /// Display a video post — sets the media type to video and performs crossfade using a placeholder
    private func displayVideo(url: URL, post: RemotePost) async {
        // Keep previous post saveable for 1.5s grace period
        if let outgoing = currentPost {
            previousPost = outgoing
            previousPostGraceTask?.cancel()
            previousPostGraceTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                previousPost = nil
            }
        }

        // Track history
        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }

        // Add to server history (API mode only)
        if !isGalleryMode {
            Task {
                try? await apiClient.addToHistory(baseURL: config.apiEndpoint, postId: post._id)
            }
        }

        // Reset auto-brightness for videos
        autoBrightnessAdjustment = 0
        autoContrastAdjustment = 1.0

        guard !Task.isCancelled else { return }

        // Cancel any pending GIF conversion from previous post
        gifConversionTask?.cancel()
        gifConversionTask = nil

        // Transition: clear image state and switch to video
        isCurrentPostAnimatedGIF = false
        currentImage = nil
        nextImage = nil
        isTransitioning = false
        currentPost = post
        currentMediaType = .video(url)
        lastAdvanceTime = Date()

        AppLogger.remoteViewer.info("Displaying video post \(post._id, privacy: .public)")

        // Send display sync (API mode only)
        if !isGalleryMode {
            if enableDisplaySync {
                wsClient.sendDisplaySync(
                    currentPost: (id: post._id, url: url.absoluteString),
                    nextPost: prefetchedImages.first.map { (id: $0.post._id, url: $0.url.absoluteString) },
                    currentList: currentTagListIndex,
                    dbCursor: dbCursor
                )
            } else {
                wsClient.sendDisplaySync(
                    currentPost: nil,
                    nextPost: nil,
                    currentList: currentTagListIndex,
                    dbCursor: nil
                )
            }
        }
    }

    /// Show an already-loaded image with crossfade, Ken Burns analysis, and brightness adjustment
    private func displayImage(_ image: UIImage, post: RemotePost, url: URL, mediaType: SlideshowMediaType = .image) async {
        // Keep previous post saveable for 1.5s grace period
        if let outgoing = currentPost {
            previousPost = outgoing
            previousPostGraceTask?.cancel()
            previousPostGraceTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                previousPost = nil
            }
        }

        // Track history
        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }

        // Add to server history (API mode only)
        if !isGalleryMode {
            Task {
                try? await apiClient.addToHistory(baseURL: config.apiEndpoint, postId: post._id)
            }
        }

        // Analyze image for Ken Burns and brightness
        if let cgImage = image.cgImage {
            if config.enableKenBurns {
                let focus = await Task.detached {
                    SobelFocusAnalyzer.focusPoint(from: cgImage)
                }.value
                focusPoint = focus
            }

            let luminance = await Task.detached {
                SobelFocusAnalyzer.averageLuminance(from: cgImage)
            }.value

            if luminance < 0.3 {
                let boost = Double(0.3 - luminance) * 0.5
                autoBrightnessAdjustment = boost
                autoContrastAdjustment = 1.0 + boost * 0.5
            } else {
                autoBrightnessAdjustment = 0
                autoContrastAdjustment = 1.0
            }
        }

        // Final cancellation check before committing to the crossfade — once we
        // start the animation we must finish it to avoid leaving the view in a
        // half-transitioned state.
        guard !Task.isCancelled else { return }

        // Cancel any pending GIF conversion from previous post
        if mediaType == .image {
            gifConversionTask?.cancel()
            gifConversionTask = nil
        }

        // Crossfade transition
        withAnimation(.easeInOut(duration: 1.0)) {
            nextImage = image
            nextPost = post
            isTransitioning = true
        }

        try? await Task.sleep(for: .seconds(1.0))
        // Use the local image/post parameters — NOT nextImage/nextPost — because
        // another interleaved displayImage() call may have overwritten those fields.
        currentImage = image
        currentPost = post
        currentMediaType = mediaType
        nextImage = nil
        isTransitioning = false
        lastAdvanceTime = Date()

        // Skip display sync if cancelled during the crossfade
        guard !Task.isCancelled else { return }

        // Send display sync (API mode only)
        if !isGalleryMode {
            if enableDisplaySync {
                wsClient.sendDisplaySync(
                    currentPost: (id: post._id, url: url.absoluteString),
                    nextPost: prefetchedImages.first.map { (id: $0.post._id, url: $0.url.absoluteString) },
                    currentList: currentTagListIndex,
                    dbCursor: dbCursor
                )
            } else {
                // Only send current list number when sync is off
                wsClient.sendDisplaySync(
                    currentPost: nil,
                    nextPost: nil,
                    currentList: currentTagListIndex,
                    dbCursor: nil
                )
            }
        }
    }

    /// Kick off background prefetch to keep the buffer full
    private func triggerPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.prefetchImages()
        }
    }

    /// Download images ahead of time so the next transition is instant
    private func prefetchImages() async {
        while prefetchedImages.count < Self.prefetchTarget, !Task.isCancelled {
            // Ensure we have post metadata
            if cachedPosts.isEmpty && !isFetching {
                await fetchMorePosts()
            }

            guard let post = nextNonBlockedPost() else { break }

            // Skip video posts for prefetch — they stream directly
            if Self.videoExtensions.contains(post.file_ext.lowercased()) {
                // Put it back so advanceToNextImage picks it up via fetchAndDisplayPost
                cachedPosts.insert(post, at: 0)
                break
            }

            guard let imageURL = resolveImageURL(for: post) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard !Task.isCancelled else { break }
                guard let image = imageFromData(data) else { continue }
                prefetchedImages.append((post: post, image: image, url: imageURL))
                AppLogger.remoteViewer.debug("Prefetched post \(post._id, privacy: .public) (\(self.prefetchedImages.count, privacy: .public)/\(Self.prefetchTarget, privacy: .public))")
            } catch {
                AppLogger.remoteViewer.warning("Prefetch failed for post \(post._id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Also ensure we have enough post metadata queued
        if cachedPosts.count < 5 && !isFetching {
            await fetchMorePosts()
        }
    }

    // MARK: - Private: Fetching

    private func fetchMorePosts() async {
        if isGalleryMode {
            await fetchGalleryPosts()
            return
        }

        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let tags: String
        if config.tagLists.isEmpty {
            tags = "order:random"
        } else {
            tags = config.tagLists[currentTagListIndex].joined(separator: " ")
        }

        var ratioRange: String?
        if config.useAspectRatio {
            let ratio = windowAspectRatio
            let min = ratio * 0.85
            let max = ratio * 1.15
            ratioRange = String(format: "%.2f..%.2f", min, max)
        }

        // Run the network request in a detached task so it isn't cancelled
        // when the slideshow task is replaced (e.g. by goToNextImage or scene phase changes)
        let apiClient = self.apiClient
        let baseURL = config.apiEndpoint
        let cursor = dbCursor
        let result: RemoteSearchResponse? = await Task.detached {
            do {
                return try await apiClient.search(
                    baseURL: baseURL,
                    tags: tags,
                    ratioRange: ratioRange,
                    cursor: cursor
                )
            } catch {
                AppLogger.remoteViewer.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value

        guard let response = result else { return }

        // Filter blocked posts client-side
        let filtered = response.results.filter { post in
            !blockedPosts.contains(post._id) &&
            !post.tags.contains(where: { blockedTags.contains($0) })
        }

        cachedPosts.append(contentsOf: filtered)
        if !filtered.isEmpty { fetchReturnedEmpty = false }

        // Update cursor from server response. If server returns 0,
        // it means we've wrapped around — re-randomize to avoid
        // fetching the same set repeatedly.
        if let next = response.nextCursor {
            let cursorStr = next.stringValue
            if cursorStr == "0" {
                dbCursor = String(Double.random(in: 0..<1))
            } else {
                dbCursor = cursorStr
            }
        }

        AppLogger.remoteViewer.info("Fetched \(response.results.count, privacy: .public) posts, \(filtered.count, privacy: .public) after filtering")
    }

    /// Fetch images from the app's gallery source for gallery mode slideshow
    private func fetchGalleryPosts() async {
        guard let source = galleryImageSource, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            var filter = galleryFilter ?? ImageFilterCriteria()
            // Override sort to random for slideshow unless user has set a specific sort
            if galleryFilter == nil {
                filter.sortField = .random
            }
            filter.randomSeed = nil
            let result = try await source.fetchImages(page: galleryPage, pageSize: 20, filter: filter)
            galleryPage += 1

            let posts = result.images.map { image in
                RemotePost(
                    _id: abs(image.id.hashValue),
                    file_ext: image.fullSizeURL.pathExtension,
                    tags: [],
                    rating: nil, image_width: nil, image_height: nil,
                    fav_count: nil, md5: nil, parent_id: nil,
                    score: nil, ratio: nil, path: image.fullSizeURL.absoluteString,
                    duration: nil
                )
            }
            // Store the URL mapping so prefetch/display can resolve them
            for (image, post) in zip(result.images, posts) {
                galleryURLMap[post._id] = image.fullSizeURL
            }
            cachedPosts.append(contentsOf: posts)
            AppLogger.remoteViewer.info("Gallery: fetched \(posts.count, privacy: .public) images")
        } catch {
            AppLogger.remoteViewer.error("Gallery fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// URL mapping for gallery mode posts (RemotePost._id → fullSizeURL)
    private var galleryURLMap: [Int: URL] = [:]

    /// Downsample image data if maxImageResolution is set, otherwise return full-size UIImage
    private func imageFromData(_ data: Data) -> UIImage? {
        if maxImageResolution > 0 {
            let maxDim = CGFloat(maxImageResolution)
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                return UIImage(data: data)
            }
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }

    /// Resolve the image URL for a post — gallery mode uses the URL map, API mode uses the /get endpoint
    func resolveImageURL(for post: RemotePost) -> URL? {
        if isGalleryMode {
            return galleryURLMap[post._id]
        }
        return apiClient.getImageURL(baseURL: config.apiEndpoint, postId: post._id)
    }

    // MARK: - Private: WebSocket

    private func setupWebSocket() {
        guard !config.wsEndpoint.isEmpty else { return }

        wsClient.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleWSMessage(message)
            }
        }

        wsClient.connect(wsEndpoint: config.wsEndpoint, deviceId: config.wsDeviceId)
    }

    private func handleWSMessage(_ message: RemoteWSMessage) {
        switch message {
        case .blocked(let posts, let tags):
            let newPosts = Set(posts).subtracting(blockedPosts)
            let newTags = Set(tags).subtracting(blockedTags)
            blockedPosts.formUnion(posts)
            blockedTags.formUnion(tags)
            // Persist server-sent blocked items into the config
            if !newPosts.isEmpty || !newTags.isEmpty {
                config.blockedPosts = Array(blockedPosts)
                config.blockedTags = Array(blockedTags)
                onConfigChanged?(config)
            }

        case .displayState(let isOn):
            // Ignore displayState(off) until the first image has been shown,
            // otherwise the server can cancel the slideshow before it starts.
            if isOn && isPaused {
                isPaused = false
                startSlideshow()
            } else if !isOn && !isPaused && currentImage != nil {
                isPaused = true
                slideshowTask?.cancel()
                slideshowTask = nil
            }

        case .currentTagList(let index):
            // Only accept server list overrides when "Server Decides" is configured
            guard config.defaultTagListIndex == nil else { return }
            guard index < config.tagLists.count else { return }
            // Ignore if already on this list — the server resends the current list
            // on reconnect (e.g. after background unload), and re-processing it
            // would nuke caches and restart the slideshow unnecessarily.
            guard index != currentTagListIndex else { return }
            currentTagListIndex = index
            persistActiveTagList()
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            dbCursor = String(Double.random(in: 0..<1))
            let firstTag = config.tagLists[index].first ?? ""
            showToast("List \(index + 1)/\(config.tagLists.count): \(firstTag)")
            goToNextImage()

        case .playVideo(let url):
            onOpenVideoWindow?(url)

        case .stopVideo:
            onDismissVideoWindow?()

        case .showText(let text, let bgColor, let imageUrl):
            onOpenAlertWindow?(text, bgColor, imageUrl)

        case .dismissText:
            onDismissAlertWindow?()

        case .sensorUpdate:
            break // Handled by wsClient.sensorData directly

        case .refresh:
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            dbCursor = String(Double.random(in: 0..<1))
            goToNextImage()

        case .displaySync(let payload):
            // Handle sync from other devices
            if let listNumber = payload["currentList"] as? Int,
               listNumber < config.tagLists.count,
               listNumber != currentTagListIndex {
                currentTagListIndex = listNumber
                persistActiveTagList()
            }
            if let cursor = payload["dbCursor"] as? String {
                dbCursor = cursor
            }
        }
    }
}
