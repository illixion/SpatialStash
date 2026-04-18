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

    // MARK: - Gallery Mode

    var isGalleryMode: Bool { contentProvider is GalleryContentProvider }

    // MARK: - Display State (remote-specific)

    var enableDisplaySync: Bool = false
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
            useAspectRatio: config.useAspectRatio
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
            fetchRemoteTagLists()
            setupWebSocket()

            // If "Server Decides" is configured and WS is active, wait 1s for the
            // server to send a currentTagList message before starting the slideshow
            if let tlm = tagListManager, tlm.serverControlEnabled && !config.wsEndpoint.isEmpty {
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

    // MARK: - Remote Tag List Fetch

    private func fetchRemoteTagLists() {
        let apiClient = self.apiClient
        let baseURL = config.apiEndpoint
        Task { [weak self] in
            do {
                let serverLists = try await apiClient.fetchTagLists(baseURL: baseURL)
                guard !serverLists.isEmpty, let self else { return }
                guard let tlm = self.tagListManager else { return }

                if tlm.tagLists != serverLists {
                    tlm.tagLists = serverLists
                    AppLogger.remoteViewer.info("Updated tag lists from tags.json: \(serverLists.count, privacy: .public) lists")
                    self.showToast("Loaded \(serverLists.count) tag lists from server")
                }
            } catch {
                AppLogger.remoteViewer.debug("tags.json not available: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    // MARK: - Display Sync (subclass hook)

    override func onPostTransitioned(post: RemotePost, url: URL) {
        // WebSocket message — still sent for RoboFrame server coordination
        // even in gallery mode (harmless if wsClient is nil).
        if !isGalleryMode {
            if enableDisplaySync {
                wsClient?.sendDisplaySync(
                    currentPost: (id: post._id, url: url.absoluteString),
                    nextPost: prefetchedImages.first.map { (id: $0.post._id, url: $0.url.absoluteString) },
                    currentList: tagListManager?.activeIndex ?? 0,
                    dbCursor: (contentProvider as? RemoteContentProvider)?.cursor
                )
            } else {
                wsClient?.sendDisplaySync(
                    currentPost: nil,
                    nextPost: nil,
                    currentList: tagListManager?.activeIndex ?? 0,
                    dbCursor: nil
                )
            }
        }

        // Local broadcast — only when sync is enabled and we aren't
        // currently applying an incoming sync (avoid feedback loops).
        guard enableDisplaySync, !isApplyingIncomingSync else { return }

        let payload = LocalDisplaySyncPayload(
            currentPost: post,
            currentImage: currentImage,
            currentImageURL: url,
            currentMediaType: currentMediaType,
            isCurrentPostAnimatedGIF: isCurrentPostAnimatedGIF,
            prefetched: prefetchedImages,
            cachedPosts: cachedPosts,
            cursor: (contentProvider as? RemoteContentProvider)?.cursor,
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

        // Mirror pagination cursor for future fetches
        if let cursor = payload.cursor {
            (contentProvider as? RemoteContentProvider)?.cursor = cursor
        }

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
        guard !config.wsEndpoint.isEmpty else { return }

        guard let result = SlideshowSyncHub.shared.subscribeWS(
            endpoint: config.wsEndpoint,
            deviceId: config.wsDeviceId,
            onMessage: { [weak self] message in
                guard let self else { return }
                self.handleWSMessage(message)
            }
        ) else { return }

        wsToken = result.token
        wsClient = result.client
    }

    private func handleWSMessage(_ message: RemoteWSMessage) {
        switch message {
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

        case .displayState(let isOn):
            if isOn && state == .paused {
                if currentImage != nil || currentMediaType != .image {
                    transition(to: .displaying)
                } else {
                    transition(to: .loading)
                }
            } else if !isOn && state == .displaying {
                transition(to: .paused)
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

        case .displaySync(let payload):
            if let listNumber = payload["currentList"] as? Int,
               let tlm = tagListManager,
               listNumber < tlm.tagLists.count,
               listNumber != tlm.activeIndex {
                tlm.switchToTagList(listNumber)
            }
            if let cursor = payload["dbCursor"] as? String {
                (contentProvider as? RemoteContentProvider)?.cursor = cursor
            }
        }
    }
}
