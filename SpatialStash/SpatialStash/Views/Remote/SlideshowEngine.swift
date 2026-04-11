/*
 Spatial Stash - Slideshow Engine

 Core slideshow engine that handles timer-driven image transitions,
 prefetching, Ken Burns focus analysis, dynamic brightness, navigation,
 toast notifications, watchdog, and background/foreground lifecycle.

 This is the reusable base class. RemoteViewerModel subclasses it to
 add WebSocket, save/block, sensor display, and display sync features.
 Gallery-mode slideshows can use this class directly.
 */

import CoreGraphics
import os
import SwiftUI
import UIKit

@MainActor
@Observable
class SlideshowEngine {
    // MARK: - Media Type

    /// The type of media currently being displayed
    enum SlideshowMediaType: Equatable {
        case image
        case video(URL)       // Video URL to play in WebVideoPlayerView
        case animatedGIF(URL) // HEVC-converted GIF URL
    }

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    // MARK: - Display State

    var currentImage: UIImage?
    var nextImage: UIImage?
    var currentPost: RemotePost?
    var nextPost: RemotePost?
    var currentMediaType: SlideshowMediaType = .image
    var isCurrentPostAnimatedGIF: Bool = false
    var isRoomActive: Bool = true
    var isTransitioning: Bool = false
    var isLoading: Bool = false
    var isPaused: Bool = false

    // Toast notifications
    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // Save grace period — keeps previous post saveable for 1.5s after transition
    var previousPost: RemotePost?
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

    /// Reference to global adjustments from AppModel
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

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

    // MARK: - Content State

    var cachedPosts: [RemotePost] = []
    var postHistory: [RemotePost] = []
    var historyImageURLs: [Int: URL] = [:]
    var isFetching: Bool = false
    var fetchReturnedEmpty: Bool = false

    // MARK: - Blocking (merged from server + local config)

    var blockedPosts: Set<Int> = []
    var blockedTags: Set<String> = []

    // MARK: - Configuration

    var delay: TimeInterval
    var enableKenBurns: Bool
    var useAspectRatio: Bool
    var maxImageResolution: Int = 0

    // MARK: - Content Provider & Tag List Manager

    var contentProvider: SlideshowContentProvider?
    var tagListManager: TagListManager?

    /// Unique ID for this engine instance, used for TagListManager registration
    let engineId = UUID()

    // MARK: - Private

    var gifConversionTask: Task<Void, Never>?
    var slideshowTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    private var backgroundUnloadTask: Task<Void, Never>?
    var watchdogTask: Task<Void, Never>?
    var backgroundedAt: Date?
    var lastAdvanceTime: Date?
    private static let backgroundUnloadDelay: TimeInterval = 30
    private static let watchdogInterval: TimeInterval = 10
    var windowAspectRatio: Double = 16.0 / 9.0

    /// Pre-downloaded images ready for instant display
    var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL)] = []
    private static let prefetchTarget = 3

    // MARK: - Init

    init(delay: TimeInterval = 15, enableKenBurns: Bool = true, useAspectRatio: Bool = true) {
        self.delay = delay
        self.enableKenBurns = enableKenBurns
        self.useAspectRatio = useAspectRatio
    }

    // MARK: - Lifecycle

    func start() {
        if let tagListManager {
            tagListManager.addChangeHandler(id: engineId) { [weak self] in
                self?.handleTagListChanged()
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
        tagListManager?.removeChangeHandler(id: engineId)
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            // Returning to active
            onBecameActive()
            isRoomActive = true
            backgroundUnloadTask?.cancel()
            backgroundUnloadTask = nil

            let wasBackgrounded = backgroundedAt
            backgroundedAt = nil

            if !isPaused {
                if let wasBackgrounded,
                   Date().timeIntervalSince(wasBackgrounded) >= Self.backgroundUnloadDelay {
                    goToNextImage()
                }
                startSlideshow()
            }
        } else if oldPhase == .active && newPhase != .active {
            onEnteredBackground()
            isRoomActive = false
            slideshowTask?.cancel()
            slideshowTask = nil
            backgroundedAt = Date()

            backgroundUnloadTask = Task {
                try? await Task.sleep(for: .seconds(Self.backgroundUnloadDelay))
                guard !Task.isCancelled else { return }
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

    /// Subclass hook for becoming active (e.g. WebSocket visibility)
    func onBecameActive() {}

    /// Subclass hook for entering background (e.g. WebSocket visibility)
    func onEnteredBackground() {}

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
    }

    // MARK: - Navigation

    func goToNextImage() {
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
        if let current = currentPost {
            cachedPosts.insert(current, at: 0)
        }
        postHistory.removeLast()
        let previous = postHistory.last!
        Task {
            await fetchAndDisplayPost(previous)
        }
    }

    func jumpToHistoryPost(_ post: RemotePost) {
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

    // MARK: - Tag List Change

    func handleTagListChanged() {
        fetchReturnedEmpty = false
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        prefetchTask?.cancel()
        contentProvider?.resetPagination()
        if let tlm = tagListManager {
            let firstTag = tlm.tagLists[safe: tlm.activeIndex]?.first ?? ""
            showToast("List \(tlm.activeIndex + 1)/\(tlm.tagLists.count): \(firstTag)")
        }
        goToNextImage()
    }

    // MARK: - Private: Slideshow

    func startSlideshow() {
        guard slideshowTask == nil else { return }
        slideshowTask = Task { [weak self] in
            guard let self else { return }

            if currentImage == nil && currentMediaType == .image {
                await advanceToNextImage()
            }

            while !Task.isCancelled {
                let delay = effectiveDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                await advanceToNextImage()
            }
        }
    }

    /// Effective delay for the current post — uses video duration if available and longer than config delay
    var effectiveDelay: TimeInterval {
        if case .video = currentMediaType,
           let duration = currentPost?.duration, duration > delay {
            return duration
        }
        return delay
    }

    func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard !Task.isCancelled else { break }

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

    private func ensurePostsAvailable() async {
        if !cachedPosts.isEmpty { return }

        if !isFetching {
            await fetchMorePosts()
        }

        var waitIterations = 0
        while isFetching && cachedPosts.isEmpty && waitIterations < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            waitIterations += 1
        }
    }

    /// Pop the next non-blocked post from the cached posts queue
    func nextNonBlockedPost() -> RemotePost? {
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
    func fetchAndDisplayPost(_ post: RemotePost) async {
        isLoading = true
        defer { isLoading = false }

        guard let imageURL = contentProvider?.resolveImageURL(for: post) else { return }

        let ext = post.file_ext.lowercased()

        // Video posts: display directly via WebVideoPlayerView without downloading
        if Self.videoExtensions.contains(ext) {
            guard !Task.isCancelled else { return }
            await displayVideo(url: imageURL, post: post)
            return
        }

        guard let result = await contentProvider?.downloadImage(for: post, maxResolution: maxImageResolution) else { return }
        guard !Task.isCancelled else { return }

        // Animated GIF: show first frame immediately, convert to HEVC in background
        if ext == "gif" && result.data.isAnimatedGIF {
            isCurrentPostAnimatedGIF = true
            await displayImage(result.image, post: post, url: imageURL, mediaType: .image)
            let data = result.data
            gifConversionTask?.cancel()
            gifConversionTask = Task { [weak self] in
                do {
                    let hevcURL = try await GIFHEVCConverter.shared.convert(gifData: data, sourceURL: imageURL)
                    guard !Task.isCancelled else { return }
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

    /// Display a video post
    func displayVideo(url: URL, post: RemotePost) async {
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

        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }

        // Notify content provider (e.g. for server-side history)
        Task { await contentProvider?.onPostDisplayed(post) }

        autoBrightnessAdjustment = 0
        autoContrastAdjustment = 1.0

        guard !Task.isCancelled else { return }

        gifConversionTask?.cancel()
        gifConversionTask = nil

        isCurrentPostAnimatedGIF = false
        currentImage = nil
        nextImage = nil
        isTransitioning = false
        currentPost = post
        currentMediaType = .video(url)
        lastAdvanceTime = Date()

        AppLogger.remoteViewer.info("Displaying video post \(post._id, privacy: .public)")

        onPostTransitioned(post: post, url: url)
    }

    /// Show an already-loaded image with crossfade, Ken Burns analysis, and brightness adjustment
    func displayImage(_ image: UIImage, post: RemotePost, url: URL, mediaType: SlideshowMediaType = .image) async {
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

        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }

        // Notify content provider (e.g. for server-side history)
        Task { await contentProvider?.onPostDisplayed(post) }

        // Analyze image for Ken Burns and brightness
        if let cgImage = image.cgImage {
            if enableKenBurns {
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

        guard !Task.isCancelled else { return }

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
        currentImage = image
        currentPost = post
        currentMediaType = mediaType
        nextImage = nil
        isTransitioning = false
        lastAdvanceTime = Date()

        guard !Task.isCancelled else { return }

        onPostTransitioned(post: post, url: url)
    }

    /// Subclass hook called after a post is fully transitioned to.
    /// Used by RemoteViewerModel for display sync.
    func onPostTransitioned(post: RemotePost, url: URL) {}

    // MARK: - Private: Prefetching

    func triggerPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.prefetchImages()
        }
    }

    private func prefetchImages() async {
        while prefetchedImages.count < Self.prefetchTarget, !Task.isCancelled {
            if cachedPosts.isEmpty && !isFetching {
                await fetchMorePosts()
            }

            guard let post = nextNonBlockedPost() else { break }

            if Self.videoExtensions.contains(post.file_ext.lowercased()) {
                cachedPosts.insert(post, at: 0)
                break
            }

            guard let imageURL = contentProvider?.resolveImageURL(for: post) else { continue }

            if let result = await contentProvider?.downloadImage(for: post, maxResolution: maxImageResolution) {
                guard !Task.isCancelled else { break }
                prefetchedImages.append((post: post, image: result.image, url: imageURL))
                AppLogger.remoteViewer.debug("Prefetched post \(post._id, privacy: .public) (\(self.prefetchedImages.count, privacy: .public)/\(Self.prefetchTarget, privacy: .public))")
            }
        }

        if cachedPosts.count < 5 && !isFetching {
            await fetchMorePosts()
        }
    }

    // MARK: - Private: Fetching

    func fetchMorePosts() async {
        guard let contentProvider, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let tagQuery = tagListManager?.activeTagQuery ?? "order:random"

        var ratioRange: String?
        if useAspectRatio {
            let ratio = windowAspectRatio
            let min = ratio * 0.85
            let max = ratio * 1.15
            ratioRange = String(format: "%.2f..%.2f", min, max)
        }

        let posts = await contentProvider.fetchMoreContent(
            tagQuery: tagQuery,
            ratioRange: ratioRange,
            blockedPosts: blockedPosts,
            blockedTags: blockedTags
        )

        cachedPosts.append(contentsOf: posts)
        if !posts.isEmpty { fetchReturnedEmpty = false }
    }
}

// MARK: - Collection safe subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
