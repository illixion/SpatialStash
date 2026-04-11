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

    // MARK: - Gallery Mode

    var isGalleryMode: Bool { contentProvider is GalleryContentProvider }

    // MARK: - Display State (remote-specific)

    var enableDisplaySync: Bool = false
    var showClock: Bool = true
    var showSensors: Bool = true

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

        // Initialize blocked lists from config
        self.blockedPosts = Set(config.blockedPosts)
        self.blockedTags = Set(config.blockedTags)
    }

    /// Callback to persist config changes back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    // MARK: - Lifecycle

    override func start() {
        if !isGalleryMode {
            // Fetch tag lists from server in the background (non-blocking)
            fetchRemoteTagLists()

            setupWebSocket()

            // If "Server Decides" is configured and WS is active, wait 1s for the
            // server to send a currentTagList message before starting the slideshow
            if let tlm = tagListManager, tlm.serverControlEnabled && !config.wsEndpoint.isEmpty {
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
        super.start()
    }

    override func stop() {
        super.stop()
        wsClient.disconnect()
    }

    override func onBecameActive() {
        wsClient.sendVisibilityChange(visible: true)
    }

    override func onEnteredBackground() {
        wsClient.sendVisibilityChange(visible: false)
    }

    // MARK: - Remote Tag List Fetch

    /// Asynchronously fetch tags.json from the API endpoint and update the
    /// shared TagListManager if the server provides tag lists.
    private func fetchRemoteTagLists() {
        let apiClient = self.apiClient
        let baseURL = config.apiEndpoint
        Task { [weak self] in
            do {
                let serverLists = try await apiClient.fetchTagLists(baseURL: baseURL)
                guard !serverLists.isEmpty, let self else { return }
                guard let tlm = self.tagListManager else { return }

                // Only update if the server lists differ from current
                if tlm.tagLists != serverLists {
                    tlm.tagLists = serverLists
                    AppLogger.remoteViewer.info("Updated tag lists from tags.json: \(serverLists.count, privacy: .public) lists")
                    self.showToast("Loaded \(serverLists.count) tag lists from server")
                }
            } catch {
                // Non-fatal — tags.json is optional
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
        wsClient.sendBlock(postId: post._id)
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
        guard !isGalleryMode else { return }

        if enableDisplaySync {
            wsClient.sendDisplaySync(
                currentPost: (id: post._id, url: url.absoluteString),
                nextPost: prefetchedImages.first.map { (id: $0.post._id, url: $0.url.absoluteString) },
                currentList: tagListManager?.activeIndex ?? 0,
                dbCursor: (contentProvider as? RemoteContentProvider)?.cursor
            )
        } else {
            wsClient.sendDisplaySync(
                currentPost: nil,
                nextPost: nil,
                currentList: tagListManager?.activeIndex ?? 0,
                dbCursor: nil
            )
        }
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
            if !newPosts.isEmpty || !newTags.isEmpty {
                config.blockedPosts = Array(blockedPosts)
                config.blockedTags = Array(blockedTags)
                onConfigChanged?(config)
            }

        case .displayState(let isOn):
            if isOn && isPaused {
                isPaused = false
                startSlideshow()
            } else if !isOn && !isPaused && currentImage != nil {
                isPaused = true
                slideshowTask?.cancel()
                slideshowTask = nil
            }

        case .currentTagList(let index):
            // Delegate to TagListManager — it handles the "Server Decides" check
            if let tlm = tagListManager {
                if tlm.handleServerTagListChange(to: index) {
                    // TagListManager already notified all engines via changeHandlers
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
            break // Handled by wsClient.sensorData directly

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
