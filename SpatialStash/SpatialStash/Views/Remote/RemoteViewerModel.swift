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

    // MARK: - Display State

    var currentImage: UIImage?
    var nextImage: UIImage?
    var currentPost: RemotePost?
    var nextPost: RemotePost?
    var isTransitioning: Bool = false
    var isLoading: Bool = false
    var isPaused: Bool = false
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

    /// Reference to global adjustments from AppModel
    var globalAdjustments: VisualAdjustments = VisualAdjustments()

    // MARK: - Content State

    var cachedPosts: [RemotePost] = []
    var postHistory: [RemotePost] = []
    var historyImageURLs: [Int: URL] = [:]
    var currentTagListIndex: Int = 0
    var dbCursor: String?
    var isFetching: Bool = false

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

    // MARK: - Private

    private var slideshowTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var windowAspectRatio: Double = 16.0 / 9.0

    /// Pre-downloaded images ready for instant display
    private var prefetchedImages: [(post: RemotePost, image: UIImage, url: URL)] = []
    private static let prefetchTarget = 3

    // MARK: - Init

    init(config: RemoteViewerConfig) {
        self.config = config
        self.showClock = config.showClock
        self.showSensors = config.showSensors
        self.currentTagListIndex = 0

        // Initialize blocked lists from config
        self.blockedPosts = Set(config.blockedPosts)
        self.blockedTags = Set(config.blockedTags)
    }

    /// Callback to persist config changes (blocked lists) back to AppModel
    var onConfigChanged: ((RemoteViewerConfig) -> Void)?

    // MARK: - Lifecycle

    func start() {
        // Randomize cursor on initial load so we don't always start at the same position
        if dbCursor == nil {
            dbCursor = String(Double.random(in: 0..<1))
        }
        setupWebSocket()
        startSlideshow()
    }

    func stop() {
        slideshowTask?.cancel()
        slideshowTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        wsClient.disconnect()
    }

    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .active && oldPhase != .active {
            wsClient.sendVisibilityChange(visible: true)
            if !isPaused {
                startSlideshow()
            }
        } else if oldPhase == .active && newPhase != .active {
            wsClient.sendVisibilityChange(visible: false)
            slideshowTask?.cancel()
            slideshowTask = nil
        }
    }

    func updateWindowAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowAspectRatio = size.width / size.height
    }

    // MARK: - Navigation

    func goToNextImage() {
        Task { await advanceToNextImage() }
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

    func cycleTagList() {
        guard !config.tagLists.isEmpty else { return }
        currentTagListIndex = (currentTagListIndex + 1) % config.tagLists.count
        // Clear cache and refetch with new tags
        cachedPosts.removeAll()
        prefetchedImages.removeAll()
        prefetchTask?.cancel()
        dbCursor = String(Double.random(in: 0..<1))
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
        slideshowTask?.cancel()
        slideshowTask = Task { [weak self] in
            guard let self else { return }

            // Initial load
            if currentImage == nil {
                await advanceToNextImage()
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.delay))
                guard !Task.isCancelled else { break }
                await advanceToNextImage()
            }
        }
    }

    private func advanceToNextImage() async {
        // Use a prefetched image if available for instant transition
        if let prefetched = prefetchedImages.first {
            prefetchedImages.removeFirst()
            await displayImage(prefetched.image, post: prefetched.post, url: prefetched.url)
            triggerPrefetch()
            return
        }

        // No prefetched images — fall back to fetch-then-display
        if cachedPosts.isEmpty && !isFetching {
            await fetchMorePosts()
        }

        guard let post = nextNonBlockedPost() else {
            AppLogger.remoteViewer.warning("No posts available")
            return
        }

        await fetchAndDisplayPost(post)
        triggerPrefetch()
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

    /// Download and display a single post (slow path, no prefetch available)
    private func fetchAndDisplayPost(_ post: RemotePost) async {
        isLoading = true
        defer { isLoading = false }

        guard let imageURL = apiClient.getImageURL(baseURL: config.apiEndpoint, postId: post._id) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            guard let image = UIImage(data: data) else { return }
            await displayImage(image, post: post, url: imageURL)
        } catch {
            AppLogger.remoteViewer.error("Failed to load post \(post._id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Show an already-loaded image with crossfade, Ken Burns analysis, and brightness adjustment
    private func displayImage(_ image: UIImage, post: RemotePost, url: URL) async {
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

        // Add to server history
        Task {
            try? await apiClient.addToHistory(baseURL: config.apiEndpoint, postId: post._id)
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

        // Crossfade transition
        withAnimation(.easeInOut(duration: 1.0)) {
            nextImage = image
            nextPost = post
            isTransitioning = true
        }

        try? await Task.sleep(for: .seconds(1.0))
        currentImage = nextImage
        currentPost = nextPost
        nextImage = nil
        isTransitioning = false

        // Send display sync
        wsClient.sendDisplaySync(
            currentPost: (id: post._id, url: url.absoluteString),
            nextPost: prefetchedImages.first.map { (id: $0.post._id, url: $0.url.absoluteString) },
            currentList: currentTagListIndex,
            dbCursor: dbCursor
        )
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
            guard let imageURL = apiClient.getImageURL(baseURL: config.apiEndpoint, postId: post._id) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard !Task.isCancelled else { break }
                guard let image = UIImage(data: data) else { continue }
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

        do {
            let response = try await apiClient.search(
                baseURL: config.apiEndpoint,
                tags: tags,
                ratioRange: ratioRange,
                cursor: dbCursor
            )

            // Filter blocked posts client-side
            let filtered = response.results.filter { post in
                !blockedPosts.contains(post._id) &&
                !post.tags.contains(where: { blockedTags.contains($0) })
            }

            cachedPosts.append(contentsOf: filtered)

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
        } catch {
            AppLogger.remoteViewer.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
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
            // Persist server-sent blocked items into the config
            if !newPosts.isEmpty || !newTags.isEmpty {
                config.blockedPosts = Array(blockedPosts)
                config.blockedTags = Array(blockedTags)
                onConfigChanged?(config)
            }

        case .displayState(let isOn):
            if isOn && isPaused {
                isPaused = false
                startSlideshow()
            } else if !isOn && !isPaused {
                isPaused = true
                slideshowTask?.cancel()
                slideshowTask = nil
            }

        case .currentTagList(let index):
            guard index < config.tagLists.count else { return }
            currentTagListIndex = index
            cachedPosts.removeAll()
            prefetchedImages.removeAll()
            dbCursor = nil
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
               listNumber < config.tagLists.count {
                currentTagListIndex = listNumber
            }
            if let cursor = payload["dbCursor"] as? String {
                dbCursor = cursor
            }
        }
    }
}
