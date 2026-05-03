/*
 Spatial Stash - Remote Viewer Model

 Subclass of SlideshowEngine that adds remote-specific features:
 WebSocket integration, save/block functionality, sensor display,
 display sync, and remote API configuration management.
 */

import os
import SwiftUI

@MainActor
class RemoteViewerModel: SlideshowEngine {
    // MARK: - Configuration

    var config: RemoteViewerConfig
    var windowValue: RemoteViewerWindowValue?

    // MARK: - Gallery Mode

    var isGalleryMode: Bool { contentProvider is GalleryContentProvider }

    // MARK: - Display State (remote-specific)

    /// User-facing toggle that claims/releases primary on the server.
    /// Writing this property emits `displaySync { enabled }`. On `true` the
    /// orchestrator promotes us to primary (driving channel timing for
    /// everyone); on `false` we go back to following.
    var enableDisplaySync: Bool = false {
        didSet {
            if oldValue != enableDisplaySync {
                wsClient?.sendDisplaySync(enabled: enableDisplaySync)
            }
        }
    }

    /// Last `playback.primary` value the server pushed. Used by the UI to
    /// reflect "you are primary" state independently of the local toggle.
    private(set) var serverPrimaryDeviceId: String?

    /// Local set of mod tags. Sent to the server via `setModTags` whenever
    /// it changes; the orchestrator includes them in its DuckDB query when
    /// this client is primary.
    var modTags: [String] = [] {
        didSet {
            if oldValue != modTags {
                wsClient?.sendSetModTags(tags: modTags)
            }
        }
    }

    var showClock: Bool = true
    var showSensors: Bool = true

    // MARK: - Sensor Display

    var sortedSensors: [HASensorReading] {
        wsClient?.sensorData.values.sorted { $0.friendlyName < $1.friendlyName } ?? []
    }

    // MARK: - Window Callbacks

    var onOpenVideoWindow: ((URL) -> Void)?
    var onDismissVideoWindow: (() -> Void)?
    var onOpenAlertWindow: ((String, String, String?) -> Void)?
    var onDismissAlertWindow: (() -> Void)?

    // MARK: - Services

    let apiClient = RemoteAPIClient()
    /// Shared WebSocket client, acquired from SlideshowSyncHub when WS is configured.
    /// Multiple RemoteViewerModels with the same wsEndpoint share a single client.
    private(set) var wsClient: RemoteWebSocketClient?
    private var wsToken: SlideshowSyncHub.WSSubscriptionToken?

    /// When true, `onPostTransitioned` skips broadcasting local sync to avoid
    /// feedback loops while this model is applying an incoming sync.
    private var isApplyingIncomingSync: Bool = false

    // MARK: - Init

    init(config: RemoteViewerConfig) {
        self.config = config
        self.showClock = config.showClock
        self.showSensors = config.showSensors

        super.init(
            delay: config.delay,
            enableKenBurns: config.enableKenBurns,
            useAspectRatio: config.useAspectRatio,
            enableDynamicBrightness: config.enableDynamicBrightness
        )

        self.blockedPosts = Set(config.blockedPosts)
        self.blockedTags = Set(config.blockedTags)
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
                    guard let self, self.state == .idle else { return }
                    // Now start the engine (idle → loading)
                    self.transition(to: .loading)
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
        SlideshowSyncHub.shared.unsubscribeWS(wsToken)
        wsToken = nil
        wsClient = nil
    }

    override func onBecameActive() {
        wsClient?.sendVisibilityChange(deviceId: config.wsDeviceId, visible: true)
    }

    override func onEnteredBackground() {
        wsClient?.sendVisibilityChange(deviceId: config.wsDeviceId, visible: false)
    }

    // MARK: - Remote Actions

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
        wsClient?.sendBlock(postId: post._id)
        onConfigChanged?(config)
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
            delay = newValue
            if config.delay != newValue {
                config.delay = newValue
                onConfigChanged?(config)
            }
        }
    }

    // MARK: - Display Sync (subclass hook)

    override func onPostTransitioned(post: RemotePost, url: URL) {
        // The server is authoritative on what's playing — no need to echo
        // the post/cursor over the WebSocket. The displaySync action is a
        // primary-claim toggle (handled in `enableDisplaySync.didSet`).

        // Local broadcast — keeps multiple visionOS windows on the same
        // host in lockstep. (When they all share one WS connection, they
        // all receive the same `playback` frames anyway, so this is mostly
        // redundant once primary mode is on; still needed for gallery mode
        // where there's no WS.)
        guard enableDisplaySync, !isApplyingIncomingSync else { return }

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

    // MARK: - Local Display Sync (receiver)

    /// Adopt a display-sync snapshot from another local slideshow instance.
    /// Images/data are reference-typed so no bitmap copies occur. Only
    /// mirrors cheap live state — pause/play and visibility are not synced.
    func applyLocalDisplaySync(_ payload: LocalDisplaySyncPayload) {
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

        guard let result = SlideshowSyncHub.shared.subscribeWS(
            endpoint: wsURL,
            deviceId: config.wsDeviceId,
            onMessage: { [weak self] message in
                guard let self else { return }
                self.handleWSMessage(message)
            }
        ) else { return }

        wsToken = result.token
        wsClient = result.client

        // Register this session with the orchestrator. The server
        // auto-promotes the first registered session to primary, then
        // broadcasts a `playback` frame which our handler picks up below.
        // Width/height are nominal — spatialstash doesn't pass them to /get.
        let intervalMs = max(2000, Int(config.delay * 1000))
        wsClient?.sendSlideshowConfig(
            deviceId: config.wsDeviceId,
            interval: intervalMs,
            width: 1920,
            height: 1080,
            bright: false,
            convert: false,
            ratio: nil
        )
        if !modTags.isEmpty {
            wsClient?.sendSetModTags(tags: modTags)
        }
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

        case .blocked(let posts, let tags):
            let newPosts = Set(posts).subtracting(blockedPosts)
            let newTags = Set(tags).subtracting(blockedTags)
            blockedPosts.formUnion(posts)
            blockedTags.formUnion(tags)
            if !newPosts.isEmpty || !newTags.isEmpty {
                config.blockedPosts = Array(blockedPosts)
                config.blockedTags = Array(blockedTags)
                onConfigChanged?(config)
            }

        case .currentTagList(let index):
            if let tlm = tagListManager {
                if tlm.handleServerTagListChange(to: index) {
                    AppLogger.remoteViewer.info("Server changed tag list to \(index, privacy: .public)")
                }
            }

        case .playVideo(let url):
            onOpenVideoWindow?(url)

        case .stopVideo:
            onDismissVideoWindow?()

        case .showText(let text, let bgColor, let imageUrl):
            onOpenAlertWindow?(text, bgColor, imageUrl)

        case .dismissText:
            onDismissAlertWindow?()

        case .sensorUpdate:
            break

        case .refresh:
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            contentProvider?.resetPagination()
            goToNextImage()

        case .playback(let payload):
            handlePlaybackFrame(payload)
        }
    }

    /// A `playback` frame from the orchestrator. Updates interval, tag
    /// list, primary status, and feeds the engine's queue with the server's
    /// `current` / `next` posts.
    private func handlePlaybackFrame(_ payload: [String: Any]) {
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

        // Primary status — server tells us who currently drives the channel.
        serverPrimaryDeviceId = payload["primary"] as? String

        let provider = contentProvider as? RemoteContentProvider
        let current = postFromPlaybackEntry(payload["current"])
        let next = postFromPlaybackEntry(payload["next"])

        if let cur = current {
            if cur._id != currentPost?._id {
                // Server's current differs from what we're showing. Queue
                // both posts and trigger an advance — the engine's prefetch
                // loop fetches the binary via /get and the displaying phase
                // crossfades to it.
                provider?.enqueueFromPlayback([cur] + (next.map { [$0] } ?? []))
                cachedPosts.removeAll()
                prefetchedImages.removeAll()
                goToNextImage()
            } else if let n = next {
                // Already on the right current; keep `next` queued for the
                // engine's lookahead.
                provider?.enqueueFromPlayback([n])
            }
        } else if let n = next {
            provider?.enqueueFromPlayback([n])
        }
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
