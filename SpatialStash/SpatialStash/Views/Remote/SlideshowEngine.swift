/*
 Spatial Stash - Slideshow Engine

 Core slideshow engine using a state machine for lifecycle management.
 Handles timer-driven image transitions, prefetching, Ken Burns focus
 analysis, dynamic brightness, navigation, and background lifecycle.

 States: idle → loading → displaying ⇄ paused / backgrounded → stopped

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
    // MARK: - State Machine

    enum SlideshowState: Equatable, CustomStringConvertible {
        case idle
        case loading
        case displaying
        case transitioning
        case paused
        case backgrounded
        case stopped

        var description: String {
            switch self {
            case .idle: "idle"
            case .loading: "loading"
            case .displaying: "displaying"
            case .transitioning: "transitioning"
            case .paused: "paused"
            case .backgrounded: "backgrounded"
            case .stopped: "stopped"
            }
        }
    }

    /// Current slideshow state. All lifecycle transitions go through `transition(to:)`.
    private(set) var state: SlideshowState = .idle

    /// Signal used to wake the run loop when state changes (e.g. unpause, next).
    /// The run loop sleeps on this; any transition increments it to break the sleep.
    private var stateVersion: Int = 0

    // MARK: - Media Type

    enum SlideshowMediaType: Equatable {
        case image
        case video(URL)
        case animatedGIF(URL)
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

    /// Convenience for views — true when state is .paused
    var isPaused: Bool { state == .paused }

    // Toast notifications
    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // Save grace period
    var previousPost: RemotePost?
    private var previousPostGraceTask: Task<Void, Never>?

    var saveablePost: RemotePost? {
        currentPost ?? previousPost
    }

    // Ken Burns
    var focusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Dynamic brightness
    var autoBrightnessAdjustment: Double = 0
    var autoContrastAdjustment: Double = 1.0

    // User visual adjustments
    var currentAdjustments: VisualAdjustments = VisualAdjustments()
    var showAdjustmentsPopover: Bool = false
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

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

    // MARK: - Blocking

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
    let engineId = UUID()

    // MARK: - Private

    var gifConversionTask: Task<Void, Never>?
    private var runLoopTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    private var backgroundUnloadTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var lastAdvanceTime: Date?
    private static let backgroundUnloadDelay: TimeInterval = 30
    var windowAspectRatio: Double = 16.0 / 9.0

    var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL)] = []
    private static let prefetchTarget = 3

    /// When set, the next run loop iteration will display this specific post
    /// instead of advancing normally. Used by previousImage/jumpToHistoryPost.
    private var pendingPost: RemotePost?

    // MARK: - Init

    init(delay: TimeInterval = 15, enableKenBurns: Bool = true, useAspectRatio: Bool = true) {
        self.delay = delay
        self.enableKenBurns = enableKenBurns
        self.useAspectRatio = useAspectRatio
    }

    // MARK: - State Transitions

    /// Central state transition — all lifecycle changes go through here.
    /// Logs transitions and wakes the run loop.
    func transition(to newState: SlideshowState) {
        let oldState = state
        guard oldState != newState else { return }

        // Validate transitions
        switch (oldState, newState) {
        case (.stopped, _) where newState != .stopped:
            AppLogger.remoteViewer.warning("Ignoring transition from stopped to \(newState.description, privacy: .public)")
            return
        default:
            break
        }

        state = newState
        stateVersion += 1

        AppLogger.remoteViewer.debug("State: \(oldState.description, privacy: .public) → \(newState.description, privacy: .public)")
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else {
            AppLogger.remoteViewer.warning("start() called in state \(self.state.description, privacy: .public), ignoring")
            return
        }

        if let tagListManager {
            tagListManager.addChangeHandler(id: engineId) { [weak self] in
                self?.handleTagListChanged()
            }
        }

        transition(to: .loading)
        startRunLoop()
    }

    func stop() {
        transition(to: .stopped)
        runLoopTask?.cancel()
        runLoopTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        gifConversionTask?.cancel()
        gifConversionTask = nil
        backgroundUnloadTask?.cancel()
        backgroundUnloadTask = nil
        tagListManager?.removeChangeHandler(id: engineId)
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            onBecameActive()
            isRoomActive = true
            backgroundUnloadTask?.cancel()
            backgroundUnloadTask = nil

            let wasBackgrounded = backgroundedAt
            backgroundedAt = nil

            guard state == .backgrounded else { return }

            if let wasBackgrounded,
               Date().timeIntervalSince(wasBackgrounded) >= Self.backgroundUnloadDelay {
                // Images were unloaded — need to load fresh
                transition(to: .loading)
            } else if currentImage != nil || currentMediaType != .image {
                // Still have content — resume displaying (timer will restart in run loop)
                transition(to: .displaying)
            } else {
                transition(to: .loading)
            }

        } else if oldPhase == .active && newPhase != .active {
            onEnteredBackground()
            isRoomActive = false
            backgroundedAt = Date()

            // Only background if we're in an active state
            if state == .displaying || state == .loading || state == .transitioning {
                transition(to: .backgrounded)
            }

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

    func onBecameActive() {}
    func onEnteredBackground() {}

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
    }

    // MARK: - Navigation

    func goToNextImage() {
        pendingPost = nil
        transition(to: .loading)
    }

    func previousImage() {
        guard postHistory.count >= 2 else { return }
        if let current = currentPost {
            cachedPosts.insert(current, at: 0)
        }
        postHistory.removeLast()
        let previous = postHistory.last!
        pendingPost = previous
        transition(to: .loading)
    }

    func jumpToHistoryPost(_ post: RemotePost) {
        pendingPost = post
        transition(to: .loading)
    }

    func togglePause() {
        switch state {
        case .displaying, .loading, .transitioning:
            transition(to: .paused)
        case .paused:
            if currentImage != nil || currentMediaType != .image {
                transition(to: .displaying)
            } else {
                transition(to: .loading)
            }
        default:
            break
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
        pendingPost = nil
        transition(to: .loading)
    }

    // MARK: - Run Loop

    /// The single run loop task that drives the slideshow. Reacts to state
    /// changes rather than being cancelled and recreated.
    func startRunLoop() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && state != .stopped {
                switch state {
                case .loading:
                    await runLoadingPhase()

                case .displaying:
                    await runDisplayingPhase()

                case .paused, .backgrounded:
                    // Sleep until state changes
                    await waitForStateChange()

                case .transitioning:
                    // Shouldn't reach here — transitioning is handled inside display methods
                    // but just in case, wait briefly
                    try? await Task.sleep(for: .milliseconds(100))

                case .idle, .stopped:
                    break
                }
            }

            AppLogger.remoteViewer.debug("Run loop exited (state: \(self.state.description, privacy: .public))")
        }
    }

    /// Wait until stateVersion changes (i.e. a transition happened).
    private func waitForStateChange() async {
        let versionAtEntry = stateVersion
        while stateVersion == versionAtEntry && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Loading phase: fetch and display the next image.
    private func runLoadingPhase() async {
        isLoading = true
        defer { isLoading = false }

        // If we have a specific post to display (prev/jump), use it
        if let post = pendingPost {
            pendingPost = nil
            await fetchAndDisplayPost(post)
            if state == .loading {
                // fetchAndDisplayPost succeeded — transition to displaying
                transition(to: .displaying)
            }
            triggerPrefetch()
            return
        }

        // Try prefetched image first for instant transition
        if let prefetched = prefetchedImages.first {
            prefetchedImages.removeFirst()
            guard state == .loading else { return }
            isCurrentPostAnimatedGIF = false
            await displayImage(prefetched.image, post: prefetched.post, url: prefetched.url)
            if state == .loading {
                transition(to: .displaying)
            }
            triggerPrefetch()
            return
        }

        // Fetch posts if needed
        await ensurePostsAvailable()
        guard state == .loading else { return }

        guard let post = nextNonBlockedPost() else {
            AppLogger.remoteViewer.warning("No posts available after fetch")
            fetchReturnedEmpty = true
            // Wait and retry rather than getting stuck
            try? await Task.sleep(for: .seconds(5))
            return
        }

        await fetchAndDisplayPost(post)
        if state == .loading {
            transition(to: .displaying)
        }
        triggerPrefetch()
    }

    /// Displaying phase: wait for the configured delay, then advance.
    private func runDisplayingPhase() async {
        let versionAtEntry = stateVersion
        lastAdvanceTime = Date()

        // Sleep for the delay duration, but wake early if state changes
        let sleepEnd = Date().addingTimeInterval(effectiveDelay)
        while Date() < sleepEnd && state == .displaying && stateVersion == versionAtEntry {
            // Sleep in small chunks so we can react to state changes promptly
            let remaining = sleepEnd.timeIntervalSince(Date())
            let chunk = min(remaining, 0.5)
            guard chunk > 0 else { break }
            try? await Task.sleep(for: .seconds(chunk))
        }

        // Only advance if we're still in displaying state and nothing interrupted us
        if state == .displaying && stateVersion == versionAtEntry {
            transition(to: .loading)
        }
    }

    /// Effective delay — uses video duration if available and longer than config delay
    var effectiveDelay: TimeInterval {
        if case .video = currentMediaType,
           let duration = currentPost?.duration, duration > delay {
            return duration
        }
        return delay
    }

    // MARK: - Content Loading

    private func ensurePostsAvailable() async {
        if !cachedPosts.isEmpty { return }

        if !isFetching {
            await fetchMorePosts()
        }

        // Wait for in-flight fetch with timeout
        var waitIterations = 0
        while isFetching && cachedPosts.isEmpty && waitIterations < 200 && state == .loading {
            try? await Task.sleep(for: .milliseconds(50))
            waitIterations += 1
        }
    }

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

    func fetchAndDisplayPost(_ post: RemotePost) async {
        guard let imageURL = contentProvider?.resolveImageURL(for: post) else { return }

        let ext = post.file_ext.lowercased()

        if Self.videoExtensions.contains(ext) {
            guard state == .loading else { return }
            await displayVideo(url: imageURL, post: post)
            return
        }

        guard let result = await contentProvider?.downloadImage(for: post, maxResolution: maxImageResolution) else { return }
        guard state == .loading else { return }

        // Animated GIF
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
                    }
                } catch {
                    AppLogger.remoteViewer.warning("GIF HEVC conversion failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        isCurrentPostAnimatedGIF = false
        await displayImage(result.image, post: post, url: imageURL)
    }

    // MARK: - Display

    func displayVideo(url: URL, post: RemotePost) async {
        trackPreviousPost()
        trackHistory(post: post, url: url)
        Task { await contentProvider?.onPostDisplayed(post) }

        autoBrightnessAdjustment = 0
        autoContrastAdjustment = 1.0

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

    func displayImage(_ image: UIImage, post: RemotePost, url: URL, mediaType: SlideshowMediaType = .image) async {
        trackPreviousPost()
        trackHistory(post: post, url: url)
        Task { await contentProvider?.onPostDisplayed(post) }

        // Analyze for Ken Burns and brightness
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

        // Bail if state changed during analysis
        guard state == .loading || state == .displaying else { return }

        if mediaType == .image {
            gifConversionTask?.cancel()
            gifConversionTask = nil
        }

        // Crossfade transition
        transition(to: .transitioning)
        withAnimation(.easeInOut(duration: 1.0)) {
            nextImage = image
            nextPost = post
            isTransitioning = true
        }

        try? await Task.sleep(for: .seconds(1.0))

        // Commit the transition using local parameters (not nextImage/nextPost)
        // to avoid races with interleaved calls
        currentImage = image
        currentPost = post
        currentMediaType = mediaType
        nextImage = nil
        isTransitioning = false
        lastAdvanceTime = Date()

        // If still transitioning (nobody interrupted), move to displaying.
        // If state was changed (e.g. goToNextImage during crossfade), respect that.
        if state == .transitioning {
            transition(to: .displaying)
        }

        onPostTransitioned(post: post, url: url)
    }

    func onPostTransitioned(post: RemotePost, url: URL) {}

    // MARK: - History Tracking

    private func trackPreviousPost() {
        if let outgoing = currentPost {
            previousPost = outgoing
            previousPostGraceTask?.cancel()
            previousPostGraceTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                previousPost = nil
            }
        }
    }

    private func trackHistory(post: RemotePost, url: URL) {
        postHistory.append(post)
        historyImageURLs[post._id] = url
        if postHistory.count > 100 { postHistory.removeFirst() }
    }

    // MARK: - Prefetching

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

    // MARK: - Fetching

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
