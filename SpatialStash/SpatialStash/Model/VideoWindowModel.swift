/*
 Spatial Stash - Video Window Model

 Per-window @Observable model for individual video player windows. Mirrors
 PhotoWindowModel: each window owns its own current video, navigation snapshot,
 3D intent, visual adjustments, playback state, A-B loop, share state, and
 auto-hide timers. This is what makes multiple video windows independent — the
 viewer no longer leans on shared AppModel.selectedVideo (which made every
 pushed window display whichever video was selected last).

 Important pattern (matching PhotoWindowModel): `init` must be side-effect-free
 because SwiftUI may re-create the view struct multiple times while `@State`
 discards duplicate models. All side effects are deferred to `start()`, called
 from onAppear.
 */

import Foundation
import os
import SwiftUI

@MainActor
@Observable
final class VideoWindowModel {

    // MARK: - Identity / Context

    /// The video currently displayed in this window (was AppModel.selectedVideo).
    var video: GalleryVideo

    /// Whether this window was opened via pushWindow (back button dismisses)
    /// vs openWindow (standalone pop-out with gallery button).
    let wasPushed: Bool

    /// The originating window value's UUID (used for RestoredWindowTracker).
    let windowValueId: UUID

    /// Shared app state (browse list, global settings, API client).
    let appModel: AppModel

    // MARK: - Navigation Snapshot

    /// Snapshot of the gallery video list when this window opened. Navigation
    /// operates over this private copy + lazily-loaded pages, never mutating
    /// AppModel state, so each window navigates independently.
    var galleryVideos: [GalleryVideo]

    /// Current index into `galleryVideos`.
    var currentIndex: Int

    /// Video source used for lazy pagination.
    let videoSource: any VideoSource

    /// Filter snapshot from when this window opened.
    let snapshotFilter: SceneFilterCriteria

    var currentPage: Int
    var hasMorePages: Bool
    let pageSize: Int
    var isLoadingMoreVideos: Bool = false
    let prefetchThreshold: Int = 5

    // MARK: - 3D / Viewing Mode (per-window intent)

    /// nil = auto-detect, true = force 3D, false = force 2D.
    var stereoscopicOverride: Bool?
    /// Chosen stereoscopic settings for this window's video.
    var video3DSettings: Video3DSettings?
    /// Drives the per-window Video3DSettingsSheet.
    var showVideo3DSettingsSheet: Bool = false

    // MARK: - Per-Window Visuals

    var isFlipped: Bool = false
    /// Per-window visual adjustments tier (falls back to global when unmodified).
    var currentAdjustments: VisualAdjustments = VisualAdjustments()

    // MARK: - Playback State (driven by the WebVideoPlayerView JS bridge)

    var currentTime: Double = 0
    var duration: Double = 0
    var isPaused: Bool = true
    /// HTML autoplay starts muted; the user can unmute via the control bar.
    var isMuted: Bool = true
    /// End of the last buffered range (seconds).
    var bufferedEnd: Double = 0
    /// True while the user is dragging the scrubber — suppresses incoming
    /// timeupdate writes so the thumb doesn't fight the drag.
    var isScrubbing: Bool = false

    /// Command hooks bound by WebVideoPlayerView.updateUIView (only when this
    /// model is passed as the player's `playbackModel`). They evaluate JS on
    /// the underlying <video> element.
    @ObservationIgnored var playCommand: (@MainActor () -> Void)?
    @ObservationIgnored var pauseCommand: (@MainActor () -> Void)?
    @ObservationIgnored var seekCommand: (@MainActor (Double) -> Void)?
    @ObservationIgnored var setMutedCommand: (@MainActor (Bool) -> Void)?

    // MARK: - A-B Loop

    /// Owns the A-B loop state machine (was a VideoWindowView @State). The
    /// player view binds its queryCurrentTime/setLoopBounds closures.
    let loopController = VideoLoopController()

    // MARK: - Share

    var isPreparingShare: Bool = false
    var shareFileURL: URL?

    // MARK: - UI Visibility

    var isUIHidden: Bool = false
    var isWindowControlsHidden: Bool = false
    /// Whether this window is in the user's current room (drives auto-resume).
    var isInActiveRoom: Bool = true
    /// True when visionOS restored this pop-out (vs. a fresh user open); starts
    /// with chrome hidden instead of arming the reveal timer.
    var isRestoredPopOut: Bool = false

    @ObservationIgnored var autoHideTask: Task<Void, Never>?
    @ObservationIgnored var windowControlsHideTask: Task<Void, Never>?

    /// Open ornament menus / popovers. `>0` pauses auto-hide so chrome doesn't
    /// vanish mid-selection.
    var openOrnamentMenuCount: Int = 0
    var showMediaInfo: Bool = false
    var showAdjustments: Bool = false
    var showShareSheet: Bool = false

    /// Whether any chrome is open that should pin the ornament/control bar.
    var hasOpenPopover: Bool {
        showMediaInfo || showAdjustments || showShareSheet || isScrubbing || openOrnamentMenuCount > 0
    }

    @ObservationIgnored private var didStart = false

    // MARK: - Initialization (side-effect-free)

    init(windowValue: VideoWindowValue, appModel: AppModel) {
        self.video = windowValue.video
        self.wasPushed = windowValue.wasPushed
        self.windowValueId = windowValue.id
        self.appModel = appModel
        self.stereoscopicOverride = windowValue.stereoscopicOverride
        self.video3DSettings = windowValue.video3DSettings

        // Snapshot the browse list + pagination so prev/next navigate over this
        // window's own copy (parallels PhotoWindowModel.init).
        self.galleryVideos = appModel.galleryVideos
        self.currentIndex = appModel.galleryVideos.firstIndex(of: windowValue.video) ?? 0
        self.videoSource = appModel.videoSource
        self.snapshotFilter = appModel.currentVideoFilter
        self.currentPage = appModel.currentVideoPage
        self.hasMorePages = appModel.hasMoreVideoPages
        self.pageSize = appModel.pageSize

        // NOTE: side effects deferred to start().
    }

    /// Call once from onAppear.
    func start() {
        guard !didStart else { return }
        didStart = true
        appModel.lastViewedVideoId = video.id
    }

    /// Call from onDisappear.
    func cleanup() {
        cancelAutoHideTimer()
        loopController.reset()
        playCommand = nil
        pauseCommand = nil
        seekCommand = nil
        setMutedCommand = nil
    }

    // MARK: - Navigation

    var hasNextVideo: Bool { currentIndex + 1 < galleryVideos.count }
    var hasPreviousVideo: Bool { currentIndex > 0 }
    var currentVideoPosition: Int { galleryVideos.isEmpty ? 0 : currentIndex + 1 }
    var videoCount: Int { galleryVideos.count }

    func nextVideo() {
        guard hasNextVideo else { return }
        currentIndex += 1
        checkAndLoadMoreIfNeeded()
        switchToVideo(galleryVideos[currentIndex])
    }

    func previousVideo() {
        guard hasPreviousVideo else { return }
        currentIndex -= 1
        switchToVideo(galleryVideos[currentIndex])
    }

    /// Switch to a different video, resetting per-window viewing state. The
    /// WebVideoPlayerView reloads automatically because its `videoURL` changes.
    func switchToVideo(_ newVideo: GalleryVideo) {
        appModel.lastViewedVideoId = newVideo.id
        video = newVideo

        // Reset per-window viewing state
        stereoscopicOverride = nil
        video3DSettings = nil
        isFlipped = false
        currentAdjustments = VisualAdjustments()
        loopController.reset()

        // Reset playback state (web view reloads as a fresh muted autoplay)
        currentTime = 0
        duration = 0
        isPaused = true
        isMuted = true
        bufferedEnd = 0
        isScrubbing = false
    }

    func loadMoreVideos() async {
        guard !isLoadingMoreVideos && hasMorePages else { return }
        isLoadingMoreVideos = true
        defer { isLoadingMoreVideos = false }
        do {
            let result = try await videoSource.fetchVideos(page: currentPage, pageSize: pageSize, filter: snapshotFilter)
            galleryVideos.append(contentsOf: result.videos)
            hasMorePages = result.hasMore
            currentPage += 1
        } catch {
            AppLogger.videoWindow.error("Failed to load more videos for window: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkAndLoadMoreIfNeeded() {
        let remaining = galleryVideos.count - currentIndex - 1
        if remaining <= prefetchThreshold && hasMorePages && !isLoadingMoreVideos {
            Task { await loadMoreVideos() }
        }
    }

    // MARK: - 3D / Viewing Mode

    /// Whether this window should render with the stereoscopic player.
    var shouldUse3DMode: Bool {
        if stereoscopicOverride == false { return false }
        if stereoscopicOverride == true || video3DSettings != nil { return true }
        return video.isStereoscopic
    }

    func set2DMode() {
        stereoscopicOverride = false
    }

    /// Resolve the best 3D settings for the current video and engage 3D, or
    /// open the settings sheet when none can be inferred.
    func enable3DMode() async {
        if let saved = await Video3DSettingsTracker.shared.loadSettings(videoId: video.stashId) {
            video3DSettings = saved
            stereoscopicOverride = true
            return
        }
        if let tagSettings = Video3DSettings.from(video: video) {
            video3DSettings = tagSettings
            stereoscopicOverride = true
            return
        }
        showVideo3DSettingsSheet = true
    }

    // MARK: - Visual Adjustments

    /// Per-window adjustments if modified, otherwise the global tier.
    var effectiveVideoAdjustments: VisualAdjustments {
        currentAdjustments.isModified ? currentAdjustments : appModel.globalVisualAdjustments
    }

    func toggleFlip() {
        isFlipped.toggle()
    }

    // MARK: - Playback Commands

    func togglePlayPause() {
        if isPaused {
            playCommand?()
        } else {
            pauseCommand?()
        }
        // Optimistic flip; reconciled by the next videoPlayback message.
        isPaused.toggle()
    }

    func beginScrub() {
        isScrubbing = true
        cancelAutoHideTimer()
    }

    func scrub(to time: Double) {
        currentTime = time
    }

    func endScrub(at time: Double) {
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = clamped
        seekCommand?(clamped)
        isScrubbing = false
        startAutoHideTimer()
    }

    func toggleMute() {
        isMuted.toggle()
        setMutedCommand?(isMuted)
    }

    /// Apply a state report from the JS bridge (ignored mid-scrub).
    func applyPlaybackState(currentTime: Double, duration: Double, paused: Bool, muted: Bool, buffered: Double) {
        guard !isScrubbing else { return }
        self.currentTime = currentTime
        if duration > 0 { self.duration = duration }
        self.isPaused = paused
        self.isMuted = muted
        self.bufferedEnd = buffered
    }

    // MARK: - Share

    func shareVideo() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        let url = video.streamURL
        let shareName = video.fileName ?? video.title

        if url.isFileURL {
            presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: url, title: shareName, originalURL: url))
            return
        }

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let namedURL = ShareSheetHelper.prepareShareFile(from: tempURL, title: shareName, originalURL: url)
            try? FileManager.default.removeItem(at: tempURL)
            presentShareSheet(url: namedURL)
        } catch {
            AppLogger.videoWindow.error("Failed to download video for sharing: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func presentShareSheet(url: URL) {
        cancelAutoHideTimer()
        shareFileURL = url
    }

    // MARK: - Auto-Hide

    func startAutoHideTimer() {
        cancelAutoHideTimer()
        guard appModel.autoHideDelay > 0 else { return }
        guard !hasOpenPopover else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled, !self.hasOpenPopover {
                isUIHidden = true
                scheduleWindowControlsHiding()
            }
        }
    }

    func scheduleWindowControlsHiding() {
        windowControlsHideTask?.cancel()
        windowControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isWindowControlsHidden = true
            }
        }
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        isWindowControlsHidden = false
    }

    func toggleUIVisibility() {
        isUIHidden.toggle()
        isWindowControlsHidden = false
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Scene Phase / Room Activity

    var videoDisplayName: String {
        video.title ?? video.streamURL.lastPathComponent
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active {
            isInActiveRoom = true
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false
        }
    }
}
