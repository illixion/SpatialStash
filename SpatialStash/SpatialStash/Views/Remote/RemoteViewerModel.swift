/*
 Spatial Stash - Remote Viewer Model

 Subclass of SlideshowEngine that adds remote-specific features:
 WebSocket integration, save/block functionality, sensor display,
 display sync, and remote API configuration management.
 */

import os
import SwiftUI

@MainActor
@Observable
class RemoteViewerModel: SlideshowEngine {
    // MARK: - Configuration

    var config: RemoteViewerConfig
    var windowValue: RemoteViewerWindowValue?

    // MARK: - Gallery Mode

    var isGalleryMode: Bool { contentProvider is GalleryContentProvider }

    // MARK: - Display State (remote-specific)

    /// User-facing toggle that claims/releases the displaySync merge driver
    /// role on the server. Writing this emits `displaySync { enabled }`. On
    /// `true` the orchestrator merges every channel into this session's
    /// channel — every connected display mirrors what we play. On `false`
    /// each channel resumes its own cadence.
    var enableDisplaySync: Bool = false {
        didSet {
            if oldValue != enableDisplaySync {
                wsSession?.sendDisplaySync(enabled: enableDisplaySync)
            }
        }
    }

    /// Last `playback.mergeDriver` value the server pushed (deviceId of the
    /// session currently holding the displaySync merge claim, or `nil` when
    /// no merge is active). Used by the UI to reflect merge state
    /// independently of the local toggle.
    private(set) var serverPrimaryDeviceId: String?

    /// Shared mod-tag preset catalog. Injected by RemoteViewerWindowView,
    /// same pattern as `tagListManager` on the engine superclass.
    var modTagManager: ModTagManager?

    var showClock: Bool = true
    var showSensors: Bool = true

    // MARK: - Sensor Display

    var sortedSensors: [HASensorReading] {
        wsSession?.sensorData.values.sorted { $0.friendlyName < $1.friendlyName } ?? []
    }

    // MARK: - Window Callbacks

    var onOpenAlertWindow: ((String, String, String?) -> Void)?
    var onDismissAlertWindow: (() -> Void)?

    // MARK: - Services

    let apiClient = RemoteAPIClient()
    /// Per-viewer logical session over a shared WebSocket connection.
    /// All viewers pointed at the same WS endpoint share one TCP/TLS path
    /// (one server-side ws) and multiplex under per-session sessionIds —
    /// see SlideshowSyncHub.subscribeWS and protocol.md.
    private(set) var wsSession: RemoteWSSession?

    /// When true, `onPostTransitioned` skips broadcasting local sync to avoid
    /// feedback loops while this model is applying an incoming sync.
    private var isApplyingIncomingSync: Bool = false

    /// While set to a future date, incoming `playback` frames are dropped
    /// on the floor. Stamped when the user picks a post from the history
    /// grid so the room's tick doesn't yank them away from the manually
    /// chosen image before they've finished looking at it. Suppression is
    /// per-window/local — other devices keep advancing.
    private var playbackSuppressedUntil: Date?

    /// Timestamp of the last `playback` frame received from the server.
    /// Used by `onBecameActive` to decide whether the channel looks stuck
    /// and needs an active recovery (re-register + requestNext) rather
    /// than the cheap ping-probe.
    private var lastPlaybackReceivedAt: Date?

    /// Post that's transitioned visually but is still waiting on the
    /// RealityKit slot to finish generating its depth map before we tell
    /// the server we're ready. Without this gate, a short channel
    /// interval (6 s, etc.) advances the room ahead of the slowest 3D
    /// client and the user sees the IPC conversion animation play during
    /// the next crossfade. Cleared when we actually send `imageReady`.
    private var pendingImageReadyPost: RemotePost?
    /// Object identities of images whose 3D depth-map generation has
    /// completed. Two-slot pipeline means at most two are live at once,
    /// so we cap the set rather than letting it grow unbounded.
    private var generatedImageIds: Set<ObjectIdentifier> = []

    // MARK: - Init

    init(config: RemoteViewerConfig) {
        self.config = config
        self.showClock = config.showClock
        self.showSensors = config.showSensors

        super.init(
            // In remote mode the channel's `interval` arrives in the first
            // `playback` frame after WS connect and overrides this. The
            // config value is only authoritative for gallery mode (no
            // apiEndpoint) and during the brief window before the first
            // playback frame in remote mode.
            delay: config.delay,
            enableKenBurns: config.enableKenBurns,
            useAspectRatio: config.useAspectRatio,
            enableDynamicBrightness: config.enableDynamicBrightness,
            enableDiorama: config.enableDiorama
        )

        // Block lists are server-only state — the orchestrator filters
        // blocked posts out of every channel's queue before broadcasting,
        // so a remote-mode kiosk never sees them. The engine's local
        // blockedPosts/blockedTags Sets stay empty here and are only
        // populated by the gallery-mode code path, where local filtering
        // is the only option (no WS).
    }

    /// Callback to persist config changes back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    // MARK: - Lifecycle

    override func start() {
        guard state == .idle else { return }

        SlideshowSyncHub.shared.registerForLocalSync(self)

        if !isGalleryMode {
            // Tag lists used to be HTTP-fetched here from `/tags.json`. The RoboFrame
            // rpcserver now pushes them on WebSocket connect (action: tagLists), so we
            // just open the socket and let the server announce.
            setupWebSocket()

            // If "Server Decides" is configured and WS is active, wait 1s for the
            // server to send a currentTagList message before starting the slideshow
            if let tlm = tagListManager, tlm.serverControlEnabled && !config.effectiveWsEndpoint.isEmpty {
                // Register tag list handler before the delay
                tagListManager?.addChangeHandler(id: engineId) { [weak self] in
                    self?.handleTagListChanged()
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    guard self.state != .stopped else { return }
                    // Playback can arrive before this delay expires and
                    // transition the engine to .loading. In that case we still
                    // need to start the run loop; only force idle -> loading.
                    if self.state == .idle {
                        self.transition(to: .loading)
                    }
                    self.startRunLoop()
                }
                return
            }
        }
        super.start()
    }

    override func stop() {
        super.stop()
        SlideshowSyncHub.shared.unregisterForLocalSync(self)
        wsSession?.close()
        modTagManager?.removeSendHandler(id: engineId)
        tagListManager?.removeSendHandler(id: engineId)
        wsSession = nil
    }

    override func onBecameActive() {
        // visionOS flips scenePhase on gaze shifts and minor system
        // interruptions, not just true sleep/wake. Probing with a ping
        // lets a healthy socket prove itself; only a missing pong
        // forces a reconnect. Unconditionally reconnecting here was
        // dropping the server session on every blip, which made the
        // broker emit displayDisconnect frames to peer kiosks.
        wsSession?.probeOrReconnect()
        wsSession?.sendVisibilityChange(deviceId: config.wsDeviceId, visible: true)

        // After sleep/wake the WS may auto-reconnect successfully but the
        // server-side channel can be left paused — visibility may not have
        // flipped value (so `notifyVisibility` no-ops) or our session may
        // still be alive in the orchestrator with a stopped dwell timer.
        // If we have no current post, or the last `playback` frame is
        // stale, actively re-register the channel and ask for the next
        // frame instead of waiting passively. Cheap probes (gaze blinks)
        // skip this path because `lastPlaybackReceivedAt` will be recent.
        let staleThreshold = max(30.0, delay * 2.0)
        let isStale: Bool = {
            guard let last = lastPlaybackReceivedAt else { return true }
            return Date().timeIntervalSince(last) > staleThreshold
        }()
        if currentPost == nil || isStale {
            AppLogger.remoteViewer.info("onBecameActive: recovering channel (currentPost=\(self.currentPost?._id ?? -1, privacy: .public), stale=\(isStale, privacy: .public))")
            sendSlideshowConfigToServer()
            wsSession?.sendRequestNext()
        }
    }

    override func onEnteredBackground() {
        wsSession?.sendVisibilityChange(deviceId: config.wsDeviceId, visible: false)
    }

    // MARK: - Remote Actions

    func saveCurrentPost() {
        guard let post = saveablePost else { return }
        Task {
            do {
                let result = try await apiClient.save(baseURL: config.apiEndpoint, postId: post._id, accessToken: config.accessToken)
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
        // Local insert keeps gallery-mode filtering working (no WS to
        // notify); in remote mode the server is the only filter and the
        // local Set is incidental.
        blockedPosts.insert(post._id)
        wsSession?.sendBlock(postId: post._id)
        showToast("Blocked post #\(post._id)")
        goToNextImage()
    }

    func toggleClock() {
        showClock.toggle()
    }

    func toggleSensors() {
        showSensors.toggle()
    }

    // MARK: - Bindable Display Toggles
    //
    // Bridging properties for the Viewer tab of VisualAdjustmentsPopover.
    // Several display flags live on both the engine (runtime source of truth)
    // and `config` (persistence). Writing through these setters keeps the
    // two in sync and triggers `onConfigChanged` so the change is saved.

    var displayShowClock: Bool {
        get { showClock }
        set {
            showClock = newValue
            if config.showClock != newValue {
                config.showClock = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayShowSensors: Bool {
        get { showSensors }
        set {
            showSensors = newValue
            if config.showSensors != newValue {
                config.showSensors = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableKenBurns: Bool {
        get { enableKenBurns }
        set {
            enableKenBurns = newValue
            if config.enableKenBurns != newValue {
                config.enableKenBurns = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDynamicBrightness: Bool {
        get { enableDynamicBrightness }
        set {
            enableDynamicBrightness = newValue
            if config.enableDynamicBrightness != newValue {
                config.enableDynamicBrightness = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayEnableDiorama: Bool {
        get { enableDiorama }
        set {
            enableDiorama = newValue
            if config.enableDiorama != newValue {
                config.enableDiorama = newValue
                onConfigChanged?(config)
            }
            // When toggled on while a post is already displayed, kick off
            // foreground generation so the overlay appears without waiting
            // for the next slide to advance.
            if newValue, let post = currentPost, let image = currentImage, currentForegroundImage == nil {
                generateDioramaForeground(post: post, image: image, isCurrent: true)
            }
        }
    }

    var displayTransparentBackground: Bool {
        get { config.transparentBackground }
        set {
            if config.transparentBackground != newValue {
                config.transparentBackground = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayUseAspectRatio: Bool {
        get { useAspectRatio }
        set {
            useAspectRatio = newValue
            if config.useAspectRatio != newValue {
                config.useAspectRatio = newValue
                onConfigChanged?(config)
            }
        }
    }

    var displayDelay: TimeInterval {
        get { delay }
        set {
            // Optimistic local update for slider responsiveness.
            delay = newValue
            if config.apiEndpoint.isEmpty {
                // Gallery mode — no server to defer to, so persist locally.
                if config.delay != newValue {
                    config.delay = newValue
                    onConfigChanged?(config)
                }
            } else {
                // Remote mode — interval is server-managed. Push to the
                // orchestrator; its clamped echo (2000–3600000 ms) lands
                // on the next playback frame and overwrites `delay`.
                // config.delay is stale here and not re-persisted.
                sendSlideshowConfigToServer()
            }
        }
    }

    // MARK: - Display Sync (subclass hook)

    override func onPostTransitioned(post: RemotePost, url: URL) {
        // Tell the server we've finished transitioning to this post. The
        // orchestrator's readiness barrier closes once every visible session
        // reports — without this the server rides the 10 s bad-network
        // fallback every cycle, drifting the channel ~10 s slower than the
        // engine's local deadline. The drift causes the engine to drain its
        // prefetch and flash the warning placeholder while the server
        // catches up. (Skip when applying an incoming local sync: the
        // transition was driven by another window, not by our own engine
        // ticking, and that window already reported.)
        if !isApplyingIncomingSync {
            if isSlideshow3DActive,
               let image = currentImage,
               !generatedImageIds.contains(ObjectIdentifier(image)) {
                // Defer until the slot reports generation complete. The
                // server's readiness barrier will hold the channel open
                // until we (or the bad-network fallback) report.
                pendingImageReadyPost = post
            } else {
                pendingImageReadyPost = nil
                wsSession?.sendImageReady(postId: post._id)
            }
        }

        // Local broadcast — gallery mode only. In remote mode each window
        // owns its own WS, and the server's per-deviceId channel (or the
        // displaySync merge driver) already pushes the same `playback`
        // frames to every connected window. Running local sync there too
        // would race those broadcasts and pull peer windows out of sync
        // with other clients (browser kiosks, node-display).
        guard isGalleryMode, enableDisplaySync, !isApplyingIncomingSync else { return }

        let payload = LocalDisplaySyncPayload(
            currentPost: post,
            currentImage: currentImage,
            currentImageURL: url,
            currentMediaType: currentMediaType,
            isCurrentPostAnimatedGIF: isCurrentPostAnimatedGIF,
            prefetched: prefetchedImages,
            cachedPosts: cachedPosts,
            delay: delay
        )
        SlideshowSyncHub.shared.broadcastLocalSync(from: self, payload: payload)
    }

    // MARK: - Slideshow 3D Generation Gate

    /// Called by `SlideshowSpatial3DLayer` whenever a slot finishes
    /// generating its IPC depth map. If the visible image is the one
    /// the engine just transitioned to and we were holding an
    /// `imageReady` event waiting on this generation, send it now.
    @MainActor
    func notifySpatial3DGenerated(image: UIImage) {
        let id = ObjectIdentifier(image)
        generatedImageIds.insert(id)
        // Cap at 4 — covers both slots plus a small backlog from a fast
        // re-cycle without growing unbounded across a long session.
        if generatedImageIds.count > 4 {
            generatedImageIds.removeFirst()
        }
        guard let pending = pendingImageReadyPost,
              let current = currentImage,
              ObjectIdentifier(current) == id else { return }
        pendingImageReadyPost = nil
        wsSession?.sendImageReady(postId: pending._id)
    }

    // MARK: - Local Display Sync (receiver)

    /// Adopt a display-sync snapshot from another local slideshow instance.
    /// Images/data are reference-typed so no bitmap copies occur. Only
    /// mirrors cheap live state — pause/play and visibility are not synced.
    func applyLocalDisplaySync(_ payload: LocalDisplaySyncPayload) {
        // Gallery mode only — see broadcast site for rationale.
        guard isGalleryMode else { return }
        // Display Sync OFF → this instance is independent; skip incoming syncs
        guard enableDisplaySync else { return }
        // Engine must be running — don't apply while idle/stopped
        guard state != .idle, state != .stopped else { return }

        isApplyingIncomingSync = true
        defer { isApplyingIncomingSync = false }

        // Mirror the slideshow interval
        if delay != payload.delay {
            delay = payload.delay
        }

        // (No cursor mirroring — the server owns pagination.)

        // Mirror the cached post queue (future query results)
        cachedPosts = payload.cachedPosts

        // Mirror prefetched images by reference (no copy)
        prefetchedImages = payload.prefetched

        // Mirror the currently-displayed post if it differs.
        // Use displayImage so the crossfade is consistent.
        guard let newPost = payload.currentPost,
              let newImage = payload.currentImage,
              let newURL = payload.currentImageURL,
              newPost._id != currentPost?._id else { return }

        // Don't interrupt a navigation in progress (previousImage/jump)
        if hasPendingNavigation { return }

        // If currently in transitioning state, wait — our own displayImage
        // would overlap. Swap directly instead.
        if state == .transitioning {
            currentImage = newImage
            currentPost = newPost
            currentMediaType = payload.currentMediaType
            isCurrentPostAnimatedGIF = payload.isCurrentPostAnimatedGIF
            return
        }

        isCurrentPostAnimatedGIF = payload.isCurrentPostAnimatedGIF
        Task { [weak self] in
            guard let self else { return }
            self.isApplyingIncomingSync = true
            await self.displayImage(newImage, post: newPost, url: newURL, mediaType: payload.currentMediaType)
            self.isApplyingIncomingSync = false
        }
    }

    // MARK: - Private: WebSocket

    private func setupWebSocket() {
        let wsURL = config.effectiveWsEndpoint
        guard !wsURL.isEmpty else { return }

        // Each viewer instance gets its own logical session id. The
        // underlying WebSocket connection is shared with any other
        // viewers pointed at the same endpoint — see SlideshowSyncHub.
        let session = SlideshowSyncHub.shared.subscribeWS(endpoint: wsURL, sessionId: engineId.uuidString)
        session.onMessage = { [weak self] message in
            self?.handleWSMessage(message)
        }
        // Replay channel binding on every (re)connection. The server
        // forgets which channel a session belongs to when the socket
        // dies, so without this the auto-reconnect succeeds at the
        // protocol level but never receives another `playback` frame
        // and the slideshow gets stuck on the last image.
        session.onConnected = { [weak self] in
            self?.sendSlideshowConfigToServer()
            self?.wsSession?.sendVisibilityChange(deviceId: self?.config.wsDeviceId ?? "", visible: true)
        }
        wsSession = session

        // If the connection was already alive when we attached (a sibling
        // viewer brought it up first), the session's onConnected won't
        // fire on its own — flip the switch ourselves so the orchestrator
        // gets our slideshowConfig immediately.
        if session.isConnected {
            sendSlideshowConfigToServer()
            session.sendVisibilityChange(deviceId: config.wsDeviceId, visible: true)
        }

        // Push later switches from the shared ModTagManager out to this
        // viewer's WS so any window's preset change reaches the server.
        modTagManager?.addSendHandler(id: engineId) { [weak self] tags in
            self?.wsSession?.sendSetModTags(tags: tags)
        }

        // Same wiring for tag list switches initiated from the viewer
        // ornament. The TagListManager only fires this on user-initiated
        // changes — server-pushed `currentTagList` frames go through a
        // separate path and are not echoed back.
        tagListManager?.addSendHandler(id: engineId) { [weak self] listNumber in
            self?.wsSession?.sendSetTagList(listNumber: listNumber)
        }
    }

    /// Register (or re-register) this session with the orchestrator. The
    /// server creates or joins us to the channel for `wsDeviceId` and
    /// broadcasts a `playback` frame which our handler picks up. Mod tags
    /// ride along so the orchestrator's first refill query already includes
    /// them — no immediate-after refill round-trip from a separate
    /// setModTags. Called once on initial connect and again from
    /// `onConnected` after every auto-reconnect.
    private func sendSlideshowConfigToServer() {
        let intervalMs = max(2000, Int(delay * 1000))
        wsSession?.sendSlideshowConfig(
            deviceId: config.wsDeviceId,
            interval: intervalMs,
            width: 1920,
            height: 1080,
            bright: false,
            convert: false,
            ratio: nil,
            modTags: modTagManager?.activeTags ?? []
        )
    }

    private func handleWSMessage(_ message: RemoteWSMessage) {
        switch message {
        case .tagLists(let lists):
            guard let tlm = tagListManager else { break }
            if !lists.isEmpty && tlm.tagLists != lists {
                tlm.tagLists = lists
                AppLogger.remoteViewer.info("Server pushed tagLists: \(lists.count, privacy: .public) lists")
                showToast("Loaded \(lists.count) tag lists from server")
            }

        case .currentTagList(let index):
            if let tlm = tagListManager {
                if tlm.handleServerTagListChange(to: index) {
                    AppLogger.remoteViewer.info("Server changed tag list to \(index, privacy: .public)")
                }
            }

        case .showText(let text, let bgColor, let imageUrl):
            onOpenAlertWindow?(text, bgColor, imageUrl)

        case .dismissText:
            onDismissAlertWindow?()

        case .playAudio(let url):
            // Window-independent: AudioServicesPlayAlertSound runs at the
            // app level so the chime fires regardless of which spatialstash
            // window (if any) is in the user's current room.
            RemoteNotificationSound.shared.play(remoteURL: url)

        case .stopAudio:
            // No client-side knob today — alert sounds are short and
            // self-terminating. Kept here so the switch stays exhaustive.
            break

        case .sensorUpdate:
            break

        case .refresh:
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            contentProvider?.resetPagination()
            goToNextImage()

        case .playback(let payload):
            handlePlaybackFrame(payload)

        case .fatalAuthError(let reason):
            // Server closed the upgrade with 1008. The WS client has
            // already halted reconnects; surface the reason so the user
            // can fix the Access Token instead of staring at a blank
            // viewer wondering why nothing is loading.
            AppLogger.remoteViewer.error("WS auth rejected: \(reason, privacy: .public)")
            showToast(reason, isError: true)
        }
    }

    /// A `playback` frame from the orchestrator. Updates interval, tag
    /// list, merge-driver status, and feeds the engine's queue with the
    /// server's `current` / `next` posts.
    private func handlePlaybackFrame(_ payload: [String: Any]) {
        lastPlaybackReceivedAt = Date()
        if let until = playbackSuppressedUntil {
            if Date() < until {
                AppLogger.remoteViewer.info("playback: suppressed (history jump active)")
                return
            }
            playbackSuppressedUntil = nil
        }
        // Interval — the channel timer source of truth. Convert ms → seconds.
        if let intervalMs = payload["interval"] as? Int, intervalMs > 0 {
            let newDelay = TimeInterval(intervalMs) / 1000.0
            if delay != newDelay { delay = newDelay }
        }

        // Tag list — server-authoritative.
        if let listNumber = payload["currentList"] as? Int,
           let tlm = tagListManager,
           listNumber >= 0, listNumber < tlm.tagLists.count,
           listNumber != tlm.activeIndex {
            _ = tlm.handleServerTagListChange(to: listNumber)
        }

        // Merge driver — server tells us who, if anyone, currently holds
        // the displaySync claim and is broadcasting to every channel.
        serverPrimaryDeviceId = payload["mergeDriver"] as? String

        let provider = contentProvider as? RemoteContentProvider
        let current = postFromPlaybackEntry(payload["current"])
        let next = postFromPlaybackEntry(payload["next"])

        let curStr = current.map { "\($0._id).\($0.file_ext)" } ?? "nil"
        let nxtStr = next.map { "\($0._id).\($0.file_ext)" } ?? "nil"
        let stateStr = "\(state)"
        AppLogger.remoteViewer.info("playback: current=\(curStr, privacy: .public) next=\(nxtStr, privacy: .public) primary=\(self.serverPrimaryDeviceId ?? "nil", privacy: .public) myDevice=\(self.config.wsDeviceId, privacy: .public) engineState=\(stateStr, privacy: .public)")

        if let cur = current {
            // The server's tick usually arrives a few ms before the
            // engine's local 15-second deadline fires (network-induced
            // skew). In that window the engine has the new current
            // sitting at the head of prefetchedImages, fully downloaded
            // and ready to display. Force-flushing here would throw all
            // that work away and drop the next loading phase straight
            // into the failure placeholder. So if the engine's next-up
            // prefetched image is already this `cur`, we trust it and
            // just keep the lookahead queue warm.
            let engineNextMatches = prefetchedImages.first?.post._id == cur._id

            if cur._id == currentPost?._id || engineNextMatches {
                if let n = next,
                   !prefetchedImages.contains(where: { $0.post._id == n._id }) {
                    provider?.enqueueFromPlayback([n])
                    triggerPrefetch()
                }
            } else if state == .displaying || state == .idle {
                // Engine doesn't have this post and is in a state where
                // jumping makes sense. prepareForRemoteJump re-arms the
                // cold-start wait so the next loading phase blocks on
                // the fresh prefetch instead of flashing the failure
                // placeholder.
                provider?.enqueueFromPlayback([cur] + (next.map { [$0] } ?? []))
                AppLogger.remoteViewer.info("playback: force-advancing to \(cur._id, privacy: .public) (was \(self.currentPost?._id ?? -1, privacy: .public))")
                prepareForRemoteJump()
            } else {
                // Engine is loading / transitioning / paused / backgrounded
                // / stopped. Don't disrupt — when it returns to a stable
                // state and ticks naturally, the latest playback push will
                // bring it forward. Just keep the queue warm.
                provider?.enqueueFromPlayback([cur] + (next.map { [$0] } ?? []))
                triggerPrefetch()
            }
        } else if let n = next {
            provider?.enqueueFromPlayback([n])
            triggerPrefetch()
        }
    }

    /// Jump to a post chosen from the shared history grid and suppress
    /// incoming `playback` frames for one full interval so the room's tick
    /// doesn't immediately overwrite the user's selection.
    func jumpToHistoryEntry(_ entry: RemoteHistoryEntry) {
        let post = RemotePost(
            _id: entry.id, file_ext: entry.ext, tags: [],
            rating: nil, image_width: nil, image_height: nil,
            fav_count: nil, md5: nil, parent_id: nil, score: nil,
            ratio: nil, path: nil, duration: nil
        )
        playbackSuppressedUntil = Date().addingTimeInterval(delay)
        jumpToHistoryPost(post)
    }

    private func postFromPlaybackEntry(_ raw: Any?) -> RemotePost? {
        guard let dict = raw as? [String: Any],
              let id = dict["id"] as? Int else { return nil }
        let ext = dict["ext"] as? String ?? ""
        return RemotePost(
            _id: id, file_ext: ext, tags: [],
            rating: nil, image_width: nil, image_height: nil,
            fav_count: nil, md5: nil, parent_id: nil, score: nil,
            ratio: nil, path: nil, duration: nil
        )
    }
}
