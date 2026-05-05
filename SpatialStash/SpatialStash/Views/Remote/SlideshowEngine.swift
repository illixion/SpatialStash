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
    /// True when the auto-advance couldn't produce an image (prefetch empty or
    /// download failed). The UI shows a warning icon placeholder. Cleared when
    /// a real image is displayed.
    var showFailurePlaceholder: Bool = false

    /// True once the slideshow has shown a real image at least once. Used to
    /// distinguish the cold-start case (allow a bounded wait for the first
    /// image, show spinner) from steady state (show placeholder immediately on
    /// missing prefetch).
    private var hasDisplayedFirstMedia: Bool = false
    /// How long runLoadingPhase will wait for the first prefetch to populate
    /// on cold start before falling through to the placeholder.
    private static let firstLoadTimeout: TimeInterval = 20

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

    /// Counter for ornament-anchored Menu drop-downs (tag list, mod tag, etc.).
    /// SwiftUI's `Menu` doesn't expose an open binding; ornaments increment
    /// when the menu's content panel appears and decrement when it dismisses.
    /// Used by the window view to suppress the diorama foreground while a
    /// menu panel is shown so the menu isn't visually occluded by the
    /// popped-forward foreground at z=40.
    var openOrnamentMenuCount: Int = 0

    var isAnyOrnamentMenuOpen: Bool {
        openOrnamentMenuCount > 0
    }

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
    var enableDynamicBrightness: Bool
    var maxImageResolution: Int = 0

    /// Diorama mode — when enabled, the engine generates an uncropped
    /// foreground (background-removed) for each loaded image so the view
    /// layer can pop the subject forward in z. Disabled by default; expensive
    /// per-image processing.
    var enableDiorama: Bool = false {
        didSet { if !enableDiorama { clearDioramaForegrounds() } }
    }

    /// Uncropped foreground for the currently displayed post, when diorama
    /// is enabled. Nil while still being generated or when diorama is off.
    var currentForegroundImage: UIImage?

    /// Subject-blurred backdrop for the currently displayed post — replaces
    /// the original as the base layer when diorama is on so the floating
    /// foreground doesn't expose a doubled silhouette.
    var currentBackdropImage: UIImage?

    /// Uncropped foreground for the prefetched next post.
    var nextForegroundImage: UIImage?

    /// Subject-blurred backdrop for the prefetched next post.
    var nextBackdropImage: UIImage?

    /// Tracks foreground generation tasks keyed by post id so we can cancel
    /// in-flight work when navigating away or disabling diorama.
    private var dioramaTasks: [Int: Task<Void, Never>] = [:]

    // MARK: - Content Provider & Tag List Manager

    var contentProvider: SlideshowContentProvider?
    var tagListManager: TagListManager?
    let engineId = UUID()

    // MARK: - Private

    var gifConversionTask: Task<Void, Never>?
    private var runLoopTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    /// The state the engine was in before being backgrounded, for proper restoration.
    private var stateBeforeBackground: SlideshowState?
    private var lastAdvanceTime: Date?

    /// Wall-clock deadline at which the current image should advance.
    /// Persists across background/foreground cycles so the timer keeps ticking
    /// while backgrounded. Reset only when a new image is displayed.
    private var displayDeadline: Date?

    /// When the engine entered an effectively-paused state (either `.paused`
    /// directly, or `.backgrounded` with a paused prior state). Used to extend
    /// `displayDeadline` by the pause duration on resume so pausing truly
    /// freezes the timer.
    private var pauseStartedAt: Date?

    // MARK: - Watchdog
    /// Periodic health check that forces progress when the engine appears
    /// stuck while the user is actively viewing the window.
    private var watchdogTask: Task<Void, Never>?
    private var watchdogLastVersion: Int = 0
    private var watchdogLastChangeAt: Date = Date()
    private static let watchdogInterval: TimeInterval = 5
    /// How long past `displayDeadline` the engine can sit in `.displaying`
    /// before the watchdog kicks it to `.loading`.
    private static let watchdogAdvanceGrace: TimeInterval = 5
    /// How long the engine can sit in `.loading` or `.transitioning` with no
    /// state change before the watchdog restarts the run loop.
    private static let watchdogStuckThreshold: TimeInterval = 60
    var windowAspectRatio: Double = 16.0 / 9.0

    var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL)] = []
    private static let prefetchTarget = 3

    /// When set, the next run loop iteration will display this specific post
    /// instead of advancing normally. Used by previousImage/jumpToHistoryPost.
    private var pendingPost: RemotePost?

    /// True while a prev/jump navigation is in flight — subclasses can use
    /// this to avoid interrupting an intentional navigation.
    var hasPendingNavigation: Bool { pendingPost != nil }

    // MARK: - Init

    init(delay: TimeInterval = 15, enableKenBurns: Bool = true, useAspectRatio: Bool = true, enableDynamicBrightness: Bool = true, enableDiorama: Bool = false) {
        self.delay = delay
        self.enableKenBurns = enableKenBurns
        self.useAspectRatio = useAspectRatio
        self.enableDynamicBrightness = enableDynamicBrightness
        self.enableDiorama = enableDiorama
    }

    // MARK: - Diorama Foreground Processing

    /// Kick off diorama foreground+backdrop generation for `post`. Stores the
    /// pair in current/next slots once ready, depending on `isCurrent` and
    /// whether the post is still the displayed/prefetched one.
    func generateDioramaForeground(post: RemotePost, image: UIImage, isCurrent: Bool) {
        guard enableDiorama else { return }
        if dioramaTasks[post.id] != nil { return }

        let postId = post.id
        let task = Task { @MainActor [weak self] in
            defer { Task { @MainActor [weak self] in self?.dioramaTasks.removeValue(forKey: postId) } }
            do {
                let pair = try await BackgroundRemover.shared.generateDioramaPair(from: image)
                guard !Task.isCancelled, let self else { return }
                if isCurrent, self.currentPost?.id == postId {
                    self.currentForegroundImage = pair.foreground
                    self.currentBackdropImage = pair.backdrop
                } else if self.nextPost?.id == postId {
                    self.nextForegroundImage = pair.foreground
                    self.nextBackdropImage = pair.backdrop
                }
            } catch {
                // Generation can fail on unsupported formats; silently skip.
            }
        }
        dioramaTasks[postId] = task
    }

    /// Drop all in-flight diorama work and clear cached foregrounds + backdrops.
    func clearDioramaForegrounds() {
        for (_, task) in dioramaTasks { task.cancel() }
        dioramaTasks.removeAll()
        currentForegroundImage = nil
        currentBackdropImage = nil
        nextForegroundImage = nil
        nextBackdropImage = nil
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

        // Track "effective pause" duration so the display deadline can be
        // extended on resume. `.paused` is always paused; `.backgrounded`
        // inherits paused state from `stateBeforeBackground`.
        let wasEffectivelyPaused: Bool
        switch oldState {
        case .paused: wasEffectivelyPaused = true
        case .backgrounded: wasEffectivelyPaused = (stateBeforeBackground == .paused)
        default: wasEffectivelyPaused = false
        }
        let willBeEffectivelyPaused: Bool
        switch newState {
        case .paused: willBeEffectivelyPaused = true
        case .backgrounded: willBeEffectivelyPaused = (oldState == .paused)
        default: willBeEffectivelyPaused = false
        }
        if !wasEffectivelyPaused && willBeEffectivelyPaused {
            pauseStartedAt = Date()
        } else if wasEffectivelyPaused && !willBeEffectivelyPaused {
            if let start = pauseStartedAt, let deadline = displayDeadline {
                displayDeadline = deadline.addingTimeInterval(Date().timeIntervalSince(start))
            }
            pauseStartedAt = nil
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
        watchdogTask?.cancel()
        watchdogTask = nil
        tagListManager?.removeChangeHandler(id: engineId)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogLastVersion = stateVersion
        watchdogLastChangeAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard !Task.isCancelled else { return }
                self?.checkWatchdog()
            }
        }
    }

    /// Health check fired every few seconds. Two distinct failure modes:
    ///
    /// 1. **Stuck in `.displaying` past deadline** — normal path should have
    ///    exited the displaying loop and transitioned to `.loading`. Force it.
    /// 2. **Stuck in `.loading`/`.transitioning` with no state progress** —
    ///    the run loop is likely blocked in an await on a network call that
    ///    never returned. Cancel and restart the run loop so the slideshow
    ///    resumes instead of freezing indefinitely on the last image.
    ///
    /// Only acts while `isRoomActive` so legitimate paused/backgrounded
    /// sleeps don't trigger intervention.
    private func checkWatchdog() {
        if stateVersion != watchdogLastVersion {
            watchdogLastVersion = stateVersion
            watchdogLastChangeAt = Date()
        }

        guard isRoomActive else { return }

        // Case 1: overdue in .displaying — force the advance the run loop missed
        if state == .displaying, let deadline = displayDeadline {
            let overdue = Date().timeIntervalSince(deadline)
            if overdue > Self.watchdogAdvanceGrace {
                AppLogger.remoteViewer.warning("Watchdog: stuck in .displaying \(Int(overdue), privacy: .public)s past deadline — forcing advance")
                transition(to: .loading)
                return
            }
        }

        // Case 2: no state change for too long while in a "should be active" state
        let stuckFor = Date().timeIntervalSince(watchdogLastChangeAt)
        if (state == .loading || state == .transitioning), stuckFor > Self.watchdogStuckThreshold {
            AppLogger.remoteViewer.warning("Watchdog: stuck in \(self.state.description, privacy: .public) for \(Int(stuckFor), privacy: .public)s — restarting run loop")
            isFetching = false
            // Clear any pending manual nav target — if we're stuck on it,
            // trying the same post again would likely hang again. The fresh
            // run loop falls through to the auto-advance path (prefetch or
            // placeholder).
            pendingPost = nil
            prefetchTask?.cancel()
            prefetchTask = nil
            runLoopTask?.cancel()
            runLoopTask = nil
            // Route through .loading so the fresh run loop re-enters cleanly.
            if state != .loading {
                transition(to: .loading)
            }
            watchdogLastChangeAt = Date()
            watchdogLastVersion = stateVersion
            startRunLoop()
        }
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            // Returning to active
            onBecameActive()
            isRoomActive = true

            guard state == .backgrounded else { return }

            // Restore to the state we were in before backgrounding.
            // Content is always preserved — the slideshow manages its own
            // memory by cycling images as it advances, so there is no
            // background unload timer.
            let restoreState = stateBeforeBackground ?? .displaying
            stateBeforeBackground = nil

            if restoreState == .paused {
                // Preserve paused state across background cycle
                transition(to: .paused)
            } else if currentImage != nil || currentMediaType != .image {
                // Resume the slideshow timer
                transition(to: .displaying)
            } else {
                // Content was never loaded (backgrounded before first fetch) — fetch fresh
                transition(to: .loading)
            }

        } else if oldPhase == .active && newPhase != .active {
            // Leaving active — on visionOS this can happen from gaze shifts,
            // system interruptions, or true backgrounding
            onEnteredBackground()
            isRoomActive = false

            // Remember current state so we can restore it properly
            if state != .stopped && state != .idle && state != .backgrounded {
                stateBeforeBackground = state
                transition(to: .backgrounded)
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

    /// Reset prefetch state and re-arm the cold-start wait so the next
    /// loading phase blocks on the new prefetch instead of dropping
    /// straight to the failure placeholder. Used by the remote viewer
    /// when the server jumps ahead of what the engine has cached so the
    /// transition reads as "image takes a moment to load" rather than
    /// "warning icon then a fresh image" — which is what users were
    /// seeing every cycle when the server's tick beat the engine's local
    /// deadline.
    func prepareForRemoteJump() {
        fetchReturnedEmpty = false
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        hasDisplayedFirstMedia = false
        prefetchTask?.cancel()
        pendingPost = nil
        transition(to: .loading)
    }

    func handleTagListChanged() {
        fetchReturnedEmpty = false
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        // Cache was just invalidated; allow the cold-start wait so the current
        // image stays on screen while the new list's first image loads,
        // instead of immediately flashing the placeholder.
        hasDisplayedFirstMedia = false
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
        startWatchdog()
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

    /// Loading phase: hand off to the next image. Auto-advances MUST NOT block
    /// on network — if no prefetched image is ready, show a placeholder and let
    /// the timer keep cycling. Manual navigation (pendingPost) is allowed to
    /// await the download since it's user-initiated.
    private func runLoadingPhase() async {
        isLoading = true
        defer { isLoading = false }

        // Manual navigation: specific post requested (prev/jump).
        // Awaits download; shows placeholder on failure.
        if let post = pendingPost {
            pendingPost = nil
            let displayed = await fetchAndDisplayPost(post)
            if !displayed {
                displayFailurePlaceholder(toast: "Image failed to load")
            }
            if state == .loading {
                transition(to: .displaying)
            }
            triggerPrefetch()
            return
        }

        // Fast path: use a prefetched image (in-memory, no network await).
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

        // Cold start: no prefetch yet because nothing has been fetched. Kick
        // prefetch and wait up to `firstLoadTimeout` seconds for it to
        // populate before falling through to the placeholder. `isLoading`
        // stays true, so the view shows the progress spinner during the wait.
        if !hasDisplayedFirstMedia {
            triggerPrefetch()
            let waitUntil = Date().addingTimeInterval(Self.firstLoadTimeout)
            while prefetchedImages.isEmpty && Date() < waitUntil && state == .loading {
                try? await Task.sleep(for: .milliseconds(250))
            }
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
            // Timed out waiting for first image — fall through to placeholder
        }

        // Steady-state miss: never block the timer on network — show the
        // placeholder so the interval is honored, kick prefetch to populate
        // for the next cycle, and return.
        let toast = cachedPosts.isEmpty ? "No images cached" : "Next image not ready"
        displayFailurePlaceholder(toast: toast)
        triggerPrefetch()
        if state == .loading {
            transition(to: .displaying)
        }
    }

    /// Switch the display to a warning-icon placeholder. Advances the deadline
    /// so the slideshow continues cycling on schedule. Used when the automatic
    /// path can't produce an image (prefetch empty or download failed).
    /// The toast is only shown on the first failure in a streak so it doesn't
    /// re-appear every tick while the slideshow is waiting on prefetch.
    private func displayFailurePlaceholder(toast: String?) {
        let wasAlreadyPlaceholder = showFailurePlaceholder
        trackPreviousPost()
        gifConversionTask?.cancel()
        gifConversionTask = nil
        currentImage = nil
        nextImage = nil
        currentForegroundImage = nil
        currentBackdropImage = nil
        nextForegroundImage = nil
        nextBackdropImage = nil
        currentPost = nil
        currentMediaType = .image
        isCurrentPostAnimatedGIF = false
        isTransitioning = false
        showFailurePlaceholder = true
        autoBrightnessAdjustment = 0
        autoContrastAdjustment = 1.0
        lastAdvanceTime = Date()
        advanceDisplayDeadline()
        if !wasAlreadyPlaceholder, let toast {
            showToast(toast, isError: true)
        }
    }

    /// Displaying phase: wait for the stored deadline, then advance.
    /// The deadline is a wall-clock target that keeps ticking across
    /// background/foreground cycles, so returning to active does not reset
    /// the timer. If the deadline has already passed (e.g. returning after
    /// a long background) the loop exits immediately and advances once.
    private func runDisplayingPhase() async {
        let versionAtEntry = stateVersion

        // Defensive: if no deadline was set (shouldn't normally happen since
        // displayImage/displayVideo set it), establish one now.
        if displayDeadline == nil {
            displayDeadline = Date().addingTimeInterval(effectiveDelay)
        }

        while state == .displaying && stateVersion == versionAtEntry {
            guard let deadline = displayDeadline else { break }
            let remaining = deadline.timeIntervalSince(Date())
            if remaining <= 0 { break }
            let chunk = min(remaining, 0.5)
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

    /// Set `displayDeadline` for the image/video that was just committed.
    ///
    /// If the previous image's deadline had already passed (natural advance
    /// or return from background), we extend the schedule by one interval
    /// so the new image's deadline is `previous + delay` — that's what gives
    /// the "5s later" behavior when the user returns mid-interval. If that
    /// continued deadline is also in the past (return after many intervals),
    /// we fall back to a fresh `now + delay` so we never cycle more than once.
    ///
    /// If the previous deadline is still in the future (manual prev/next, or
    /// the first image at startup), the new image gets a fresh `now + delay`.
    private func advanceDisplayDeadline() {
        let now = Date()
        let delay = effectiveDelay
        if let previous = displayDeadline, now >= previous {
            let continued = previous.addingTimeInterval(delay)
            displayDeadline = continued > now ? continued : now.addingTimeInterval(delay)
        } else {
            displayDeadline = now.addingTimeInterval(delay)
        }
        // Starting a fresh image invalidates any pending pause-start marker.
        pauseStartedAt = nil
    }

    // MARK: - Content Loading

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

    /// Download and display the given post. Returns true on success, false on
    /// failure (caller can show a placeholder). State-change bailouts return
    /// true since the work was implicitly superseded, not failed.
    @discardableResult
    func fetchAndDisplayPost(_ post: RemotePost) async -> Bool {
        guard let imageURL = contentProvider?.resolveImageURL(for: post) else { return false }

        let ext = post.file_ext.lowercased()

        if Self.videoExtensions.contains(ext) {
            guard state == .loading else { return true }
            await displayVideo(url: imageURL, post: post)
            return true
        }

        guard let result = await contentProvider?.downloadImage(for: post, maxResolution: maxImageResolution) else { return false }
        guard state == .loading else { return true }

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
            return true
        }

        isCurrentPostAnimatedGIF = false
        await displayImage(result.image, post: post, url: imageURL)
        return true
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
        showFailurePlaceholder = false
        hasDisplayedFirstMedia = true
        currentImage = nil
        nextImage = nil
        currentForegroundImage = nil
        currentBackdropImage = nil
        nextForegroundImage = nil
        nextBackdropImage = nil
        isTransitioning = false
        currentPost = post
        currentMediaType = .video(url)
        lastAdvanceTime = Date()
        advanceDisplayDeadline()

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

            if enableDynamicBrightness {
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
        showFailurePlaceholder = false
        hasDisplayedFirstMedia = true
        lastAdvanceTime = Date()
        advanceDisplayDeadline()

        // Promote prefetched diorama pair (if any) to current; if not ready,
        // kick off generation. The next slot is cleared on promotion.
        if enableDiorama && mediaType == .image {
            currentForegroundImage = nextForegroundImage
            currentBackdropImage = nextBackdropImage
            nextForegroundImage = nil
            nextBackdropImage = nil
            if currentForegroundImage == nil {
                generateDioramaForeground(post: post, image: image, isCurrent: true)
            }
        } else {
            currentForegroundImage = nil
            currentBackdropImage = nil
            nextForegroundImage = nil
            nextBackdropImage = nil
        }

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

                // Pre-process diorama foreground for the upcoming post so the
                // overlay is ready the moment it transitions in.
                if enableDiorama {
                    generateDioramaForeground(post: post, image: result.image, isCurrent: false)
                }
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
