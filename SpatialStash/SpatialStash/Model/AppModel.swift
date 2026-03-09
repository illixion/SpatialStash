/*
 Spatial Stash - App Model

 The main model containing observable data used across the views.
 Includes navigation state, gallery management, and spatial image handling.
 */

import os
import RealityKit
import SwiftUI

enum Spatial3DImageState {
    case notGenerated
    case generating
    case generated
}

enum BackgroundRemovalState {
    case original
    case removing
    case removed
}

@MainActor
@Observable
class AppModel {
    // MARK: - Navigation State

    var selectedTab: Tab = .pictures
    var isShowingVideoDetail: Bool = false
    var isPictureViewerActive: Bool = false

    /// Tracks the last content tab (pictures or videos) for filter context
    var lastContentTab: Tab = .pictures

    /// Incremented when Local tab is tapped while already on Local tab
    var localTabReselected: Int = 0

    // MARK: - Server Configuration (with UserDefaults persistence)

    var stashServerURL: String {
        didSet {
            if stashServerURL != oldValue {
                UserDefaults.standard.set(stashServerURL, forKey: "stashServerURL")
                updateAPIClient()
            }
        }
    }

    var stashAPIKey: String {
        didSet {
            if stashAPIKey != oldValue {
                UserDefaults.standard.set(stashAPIKey, forKey: "stashAPIKey")
                updateAPIClient()
            }
        }
    }

    var galleryImages: [GalleryImage] = []
    var isLoadingGallery: Bool = false
    var currentPage: Int = 0
    var hasMorePages: Bool = true
    /// Incremented on each loadInitialGallery; stale loadNextPage results are discarded
    private var galleryLoadGeneration: Int = 0

    var pageSize: Int = 30

    /// Available page size options for the picker
    static let pageSizeOptions: [Int] = [10, 20, 30, 50, 100]

    // MARK: - Video Gallery State

    var galleryVideos: [GalleryVideo] = []
    var isLoadingVideos: Bool = false
    var currentVideoPage: Int = 0
    var hasMoreVideoPages: Bool = true
    /// Incremented on each loadInitialVideos; stale loadNextVideoPage results are discarded
    private var videoLoadGeneration: Int = 0

    // MARK: - Video Share State

    var isPreparingVideoShare: Bool = false
    var videoShareFileURL: URL?

    // MARK: - Stereoscopic Video Immersive State

    /// Whether the stereoscopic video immersive space is currently shown
    var isStereoscopicImmersiveSpaceShown: Bool = false

    /// The video currently being played in immersive mode
    var immersiveVideo: GalleryVideo?

    /// URL of the converted MV-HEVC file for immersive playback
    var immersiveVideoURL: URL?

    /// Override for stereoscopic video viewing mode: nil = auto (stereo for 3D content), false = force mono (left eye only)
    var videoStereoscopicOverride: Bool? = nil

    /// Custom 3D settings for the current video (used when manually enabling 3D mode)
    var video3DSettings: Video3DSettings?

    /// Whether to show the 3D settings sheet
    var showVideo3DSettingsSheet: Bool = false

    // MARK: - Filter State

    var currentFilter: ImageFilterCriteria = ImageFilterCriteria()
    var currentVideoFilter: SceneFilterCriteria = SceneFilterCriteria()
    var savedViews: [SavedView] = []
    var selectedSavedView: SavedView?
    var savedVideoViews: [SavedVideoView] = []
    var selectedSavedVideoView: SavedVideoView?

    // MARK: - Autocomplete State

    var availableGalleries: [AutocompleteItem] = []
    var availableTags: [AutocompleteItem] = []
    var availableStudios: [AutocompleteItem] = []
    var availablePerformers: [AutocompleteItem] = []
    var isLoadingGalleries: Bool = false
    var isLoadingTags: Bool = false
    var isLoadingStudios: Bool = false
    var isLoadingPerformers: Bool = false

    // MARK: - API Client

    private var apiClient: StashAPIClient

    // MARK: - Image Source (stored, always Stash server)

    private(set) var imageSource: any ImageSource

    // MARK: - Video Source (stored, always Stash server)

    private(set) var videoSource: any VideoSource

    // MARK: - Selected Items for Detail View

    var selectedImage: GalleryImage?
    var selectedVideo: GalleryVideo?

    // MARK: - Scroll Position Tracking

    var lastViewedImageId: UUID?
    var lastViewedVideoId: UUID?

    // MARK: - Main Window State

    /// Whether the main gallery window is currently open (prevents duplicates)
    var isMainWindowOpen: Bool = false

    /// Timestamp of AppModel creation — used to distinguish launch-time duplicate
    /// windows from keyboard/sheet-triggered scene recreations.
    let launchTime = Date()

    var mainWindowSize: CGSize = CGSize(width: 1200, height: 800)

    // MARK: - Photo Window Memory Management

    /// Number of currently open pop-out photo windows
    var openPhotoWindowCount: Int = 0

    /// Request to open a photo window (consumed by ContentView)
    struct PhotoWindowOpenRequest: Identifiable {
        let id = UUID()
        let image: GalleryImage
        let bypassDuplicatePrompt: Bool
    }

    /// Current open request being processed
    var activePhotoWindowOpenRequest: PhotoWindowOpenRequest?

    /// Queue for pending photo window open requests
    private var queuedPhotoWindowOpenRequests: [PhotoWindowOpenRequest] = []

    /// Allow opening duplicate windows for the current request
    private var allowDuplicateOpen: Bool = false

    func enqueuePhotoWindowOpen(
        _ image: GalleryImage,
        bypassDuplicatePrompt: Bool = false
    ) {
        let request = PhotoWindowOpenRequest(
            image: image,
            bypassDuplicatePrompt: bypassDuplicatePrompt
        )
        queuedPhotoWindowOpenRequests.append(request)

        if activePhotoWindowOpenRequest == nil {
            activePhotoWindowOpenRequest = queuedPhotoWindowOpenRequests.removeFirst()
        }
    }

    func shouldConfirmDuplicateOpen(for request: PhotoWindowOpenRequest) -> Bool {
        if request.bypassDuplicatePrompt || allowDuplicateOpen {
            return false
        }

        return hasOpenPopOutWindow(for: request.image.fullSizeURL)
    }

    func confirmDuplicateOpen() {
        allowDuplicateOpen = true
    }

    func advancePhotoWindowOpenQueue() {
        if queuedPhotoWindowOpenRequests.isEmpty {
            activePhotoWindowOpenRequest = nil
            allowDuplicateOpen = false
        } else {
            activePhotoWindowOpenRequest = queuedPhotoWindowOpenRequests.removeFirst()
            allowDuplicateOpen = false
        }
    }

    func cancelPendingPhotoWindowOpens() {
        queuedPhotoWindowOpenRequests.removeAll()
        activePhotoWindowOpenRequest = nil
        allowDuplicateOpen = false
    }

    // MARK: - Pop-Out Window Tracking

    /// Tracks open pop-out photo windows by image fullSizeURL string.
    /// Maps image URL string → array of PhotoWindowValue instances.
    /// Used to detect duplicate windows for the same image.
    var openPopOutWindows: [String: [PhotoWindowValue]] = [:]

    /// Register a pop-out window as open
    func registerPopOutWindow(imageURL: URL, windowValue: PhotoWindowValue) {
        let key = imageURL.absoluteString
        var values = openPopOutWindows[key] ?? []
        values.append(windowValue)
        openPopOutWindows[key] = values
    }

    /// Unregister a pop-out window when closed
    func unregisterPopOutWindow(imageURL: URL, windowValueId: UUID) {
        let key = imageURL.absoluteString
        openPopOutWindows[key]?.removeAll { $0.id == windowValueId }
        if openPopOutWindows[key]?.isEmpty == true {
            openPopOutWindows.removeValue(forKey: key)
        }
    }

    /// Check if any pop-out window exists for the given image URL
    func hasOpenPopOutWindow(for imageURL: URL) -> Bool {
        let key = imageURL.absoluteString
        return !(openPopOutWindows[key]?.isEmpty ?? true)
    }

    /// Get all open pop-out window values for the given image URL
    func popOutWindowValues(for imageURL: URL) -> [PhotoWindowValue] {
        let key = imageURL.absoluteString
        return openPopOutWindows[key] ?? []
    }

    /// Whether pop-out windows should use lightweight SwiftUI Image display
    /// instead of RealityKit. Activated on memory warning to free GPU resources.
    var useLightweightDisplay: Bool = false

    /// Incremented on each memory warning. PhotoDisplayView observes this to
    /// trigger a 75% scale-down of display images across all open windows.
    var memoryPressureGeneration: Int = 0

    // MARK: - Memory Recovery

    /// Counter observed by PhotoDisplayView to trigger per-window quality restoration.
    /// Incremented one-at-a-time with delays between each to allow gradual recovery.
    var memoryRecoveryGeneration: Int = 0

    /// Task that performs gradual quality recovery after memory pressure subsides
    private var memoryRecoveryTask: Task<Void, Never>?

    /// Cooldown before attempting recovery (doubles on each failed attempt, resets on full success)
    private var recoveryCooldownSeconds: Double = 30

    // MARK: - UI Visibility State (for immersive image viewing)

    /// Whether the UI (ornaments, navbar) should be hidden in detail view
    var isUIHidden: Bool = false

    /// Timer for auto-hiding UI after inactivity
    private var autoHideTask: Task<Void, Never>?

    /// Duration before auto-hiding UI (in seconds), 0 means disabled
    var autoHideDelay: TimeInterval {
        didSet {
            if autoHideDelay != oldValue {
                UserDefaults.standard.set(autoHideDelay, forKey: "autoHideDelay")
            }
        }
    }

    /// Available auto-hide delay options (0 = disabled)
    static let autoHideDelayOptions: [(label: String, value: TimeInterval)] = [
        ("Disabled", 0),
        ("2 seconds", 2),
        ("3 seconds", 3),
        ("5 seconds", 5),
        ("10 seconds", 10)
    ]

    // MARK: - Viewer Lazy Loading State

    /// Snapshotted video filter for viewer navigation (captured when viewer opens)
    private var viewerVideoFilter: SceneFilterCriteria?

    /// Whether a video viewer page load is in progress
    private(set) var isLoadingVideoViewerPage: Bool = false

    /// How many items from end before prefetching next page
    private let viewerPrefetchThreshold: Int = 5

    // MARK: - Image Display Settings

    /// Maximum image resolution in pixels. Images are downsampled to this cap
    /// (with window-based optimization within the cap). 0 = Off (full native resolution).
    var maxImageResolution: Int {
        didSet {
            if maxImageResolution != oldValue {
                UserDefaults.standard.set(maxImageResolution, forKey: "maxImageResolution")
            }
        }
    }

    /// Available max image resolution options (value 0 = Off / no limit)
    static let maxImageResolutionOptions: [(label: String, value: Int)] = [
        ("1024px", 1024),
        ("2048px", 2048),
        ("3072px", 3072),
        ("4096px", 4096),
        ("5120px", 5120),
        ("6144px", 6144),
        ("7168px", 7168),
        ("8192px", 8192),
        ("Off", 0),
    ]

    /// When true, image viewer windows have rounded corners.
    var roundedCorners: Bool {
        didSet {
            if roundedCorners != oldValue {
                UserDefaults.standard.set(roundedCorners, forKey: "roundedCorners")
            }
        }
    }

    /// When true, image selections open in separate pop-out windows instead of
    /// replacing the main app grid with a pushed picture viewer.
    var openImagesInSeparateWindows: Bool {
        didSet {
            if openImagesInSeparateWindows != oldValue {
                UserDefaults.standard.set(openImagesInSeparateWindows, forKey: "openImagesInSeparateWindows")
            }
        }
    }

    /// When true, per-image viewing enhancements (spatial 3D, background removal)
    /// are remembered and auto-restored on reopen. Turning off clears all saved data.
    var rememberImageEnhancements: Bool {
        didSet {
            if rememberImageEnhancements != oldValue {
                UserDefaults.standard.set(rememberImageEnhancements, forKey: "rememberImageEnhancements")
                if !rememberImageEnhancements {
                    Task {
                        await ImageEnhancementTracker.shared.clearAll()
                    }
                }
            }
        }
    }

    // MARK: - Slideshow Settings

    /// Slideshow delay between images (in seconds)
    var slideshowDelay: TimeInterval {
        didSet {
            if slideshowDelay != oldValue {
                UserDefaults.standard.set(slideshowDelay, forKey: "slideshowDelay")
            }
        }
    }

    /// Available slideshow delay options (in seconds)
    static let slideshowDelayOptions: [TimeInterval] = [
        3, 5, 10, 15, 20, 30, 45, 60, 90, 120
    ]

    // MARK: - Initialization

    init() {
        // Load persisted settings or use defaults (use local vars to avoid self reference issues)
        let defaultServerURL = ""
        let defaultAPIKey = ""
        let defaultAutoHideDelay: TimeInterval = 3.0
        let defaultSlideshowDelay: TimeInterval = 5.0

        let loadedServerURL = UserDefaults.standard.string(forKey: "stashServerURL") ?? defaultServerURL
        let loadedAPIKey = UserDefaults.standard.string(forKey: "stashAPIKey") ?? defaultAPIKey

        // Load auto-hide delay (0 means disabled, use default if not set)
        let savedAutoHideDelay = UserDefaults.standard.double(forKey: "autoHideDelay")
        let loadedAutoHideDelay = UserDefaults.standard.object(forKey: "autoHideDelay") != nil ? savedAutoHideDelay : defaultAutoHideDelay

        // Load slideshow delay
        let savedSlideshowDelay = UserDefaults.standard.double(forKey: "slideshowDelay")
        let loadedSlideshowDelay = UserDefaults.standard.object(forKey: "slideshowDelay") != nil ? savedSlideshowDelay : defaultSlideshowDelay

        // Load max image resolution (default: 4096, migrate from old bool key if needed)
        let loadedMaxImageResolution: Int
        if UserDefaults.standard.object(forKey: "maxImageResolution") != nil {
            loadedMaxImageResolution = UserDefaults.standard.integer(forKey: "maxImageResolution")
        } else if UserDefaults.standard.object(forKey: "dynamicImageResolution") != nil {
            // Migrate from old boolean setting: true → 4096, false → 0 (Off)
            loadedMaxImageResolution = UserDefaults.standard.bool(forKey: "dynamicImageResolution") ? 4096 : 0
            UserDefaults.standard.set(loadedMaxImageResolution, forKey: "maxImageResolution")
            UserDefaults.standard.removeObject(forKey: "dynamicImageResolution")
        } else {
            loadedMaxImageResolution = 4096
        }

        // Load rounded corners (default: true)
        let loadedRoundedCorners = UserDefaults.standard.object(forKey: "roundedCorners") != nil
            ? UserDefaults.standard.bool(forKey: "roundedCorners")
            : true

        // Load image opening mode (default: false = open in main window)
        let loadedOpenImagesInSeparateWindows = UserDefaults.standard.object(forKey: "openImagesInSeparateWindows") != nil
            ? UserDefaults.standard.bool(forKey: "openImagesInSeparateWindows")
            : false

        // Load remember image enhancements (default: true)
        let loadedRememberImageEnhancements = UserDefaults.standard.object(forKey: "rememberImageEnhancements") != nil
            ? UserDefaults.standard.bool(forKey: "rememberImageEnhancements")
            : true

        // Initialize stored properties
        self.stashServerURL = loadedServerURL
        self.stashAPIKey = loadedAPIKey
        self.autoHideDelay = loadedAutoHideDelay
        self.slideshowDelay = loadedSlideshowDelay
        self.maxImageResolution = loadedMaxImageResolution
        self.roundedCorners = loadedRoundedCorners
        self.openImagesInSeparateWindows = loadedOpenImagesInSeparateWindows
        self.rememberImageEnhancements = loadedRememberImageEnhancements

        // Initialize API client and image sources
        let client: StashAPIClient
        if !loadedServerURL.isEmpty, let url = URL(string: loadedServerURL) {
            // Use Stash server if configured
            let config = StashServerConfig(
                serverURL: url,
                apiKey: loadedAPIKey.isEmpty ? nil : loadedAPIKey
            )
            client = StashAPIClient(config: config)
            self.apiClient = client
            self.imageSource = GraphQLImageSource(apiClient: client)
            self.videoSource = GraphQLVideoSource(apiClient: client)
            AppLogger.appModel.info("Init - Using Stash Server: \(loadedServerURL, privacy: .private)")
        } else {
            // Fallback to example images if no server configured
            let defaultConfig = StashServerConfig.default
            client = StashAPIClient(config: defaultConfig)
            self.apiClient = client
            self.imageSource = StaticURLImageSource()
            self.videoSource = GraphQLVideoSource(apiClient: client)
            AppLogger.appModel.info("Init - No Stash Server configured, using example images")
        }

        // Now all stored properties are initialized, we can use self
        AppLogger.appModel.info("Init - Has API Key: \(!self.stashAPIKey.isEmpty, privacy: .public)")
        AppLogger.appModel.info("Init - Page Size: 30")

        // Load saved views and window groups from UserDefaults
        loadSavedViews()
        loadSavedVideoViews()
        loadSavedWindowGroups()

        // Apply default views on startup
        applyDefaultViewsOnStartup()

        // Monitor memory pressure and clear caches when warned
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLogger.appModel.warning("Memory warning received — scaling down textures and clearing caches")
            Task { @MainActor [weak self] in
                guard let self else { return }

                // If recovery was in progress, increase cooldown (the system wasn't ready)
                if self.memoryRecoveryTask != nil {
                    self.recoveryCooldownSeconds = min(self.recoveryCooldownSeconds * 2, 300)
                    AppLogger.appModel.info("Recovery interrupted — cooldown increased to \(Int(self.recoveryCooldownSeconds))s")
                }
                self.memoryRecoveryTask?.cancel()
                self.memoryRecoveryTask = nil

                await ImageLoader.shared.clearMemoryCache()
                // Switch any 3D windows to lightweight mode
                self.useLightweightDisplay = true
                // Trigger 75% scale-down of all display images
                self.memoryPressureGeneration += 1

                // Schedule gradual recovery after cooldown
                self.scheduleMemoryRecovery()
            }
        }
    }

    // MARK: - Memory Recovery

    /// Schedule gradual quality recovery after memory pressure subsides.
    /// Waits for cooldown, then restores one window at a time.
    /// If a new memory warning fires during recovery, it cancels and re-schedules with longer cooldown.
    private func scheduleMemoryRecovery() {
        memoryRecoveryTask?.cancel()
        let cooldown = recoveryCooldownSeconds

        memoryRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(cooldown))
            guard !Task.isCancelled, let self else { return }

            AppLogger.appModel.info("Starting memory recovery after \(Int(cooldown))s cooldown")

            // Reset useLightweightDisplay so 3D can be re-enabled by user
            self.useLightweightDisplay = false

            // Gradually restore quality: increment recovery generation once per window,
            // with a pause between each to let the system settle.
            let windowCount = self.openPhotoWindowCount
            for i in 0..<windowCount {
                guard !Task.isCancelled else { return }
                self.memoryRecoveryGeneration += 1
                AppLogger.appModel.info("Recovery step \(i + 1)/\(windowCount)")

                // Wait between restorations to let system settle and detect new warnings
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
            }

            // Full recovery succeeded — reset cooldown for next time
            self.recoveryCooldownSeconds = 30
            AppLogger.appModel.info("Memory recovery complete")
        }
    }

    // MARK: - Saved Views Persistence

    private static let savedViewsKey = "savedViews"

    private func loadSavedViews() {
        if let data = UserDefaults.standard.data(forKey: Self.savedViewsKey),
           let views = try? JSONDecoder().decode([SavedView].self, from: data) {
            savedViews = views
            AppLogger.appModel.info("Loaded \(views.count, privacy: .public) saved views")
        }
    }

    func saveSavedViews() {
        if let data = try? JSONEncoder().encode(savedViews) {
            UserDefaults.standard.set(data, forKey: Self.savedViewsKey)
            let count = savedViews.count
            AppLogger.appModel.info("Saved \(count, privacy: .public) views")
        }
    }

    func createSavedView(name: String) {
        let view = SavedView(name: name, filter: currentFilter)
        savedViews.append(view)
        saveSavedViews()
    }

    func updateSavedView(_ view: SavedView, with filter: ImageFilterCriteria) {
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[index].updateFilter(filter)
            saveSavedViews()
        }
    }

    func deleteSavedView(_ view: SavedView) {
        savedViews.removeAll { $0.id == view.id }
        if selectedSavedView?.id == view.id {
            selectedSavedView = nil
        }
        saveSavedViews()
    }

    func applySavedView(_ view: SavedView) {
        currentFilter = view.filter
        normalizeEmptyMultiSelectModifiers(&currentFilter)
        selectedSavedView = view
        Task {
            await loadInitialGallery()
        }
    }

    func deselectView() {
        currentFilter = ImageFilterCriteria()
        selectedSavedView = nil
        Task {
            await loadInitialGallery()
        }
    }

    func setDefaultView(_ view: SavedView) {
        // Clear any existing default
        for index in savedViews.indices {
            savedViews[index].isDefault = false
        }
        // Set the new default
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[index].isDefault = true
        }
        saveSavedViews()
    }

    func clearDefaultView() {
        for index in savedViews.indices {
            savedViews[index].isDefault = false
        }
        saveSavedViews()
    }

    // MARK: - Saved Video Views Persistence

    private static let savedVideoViewsKey = "savedVideoViews"

    private func loadSavedVideoViews() {
        if let data = UserDefaults.standard.data(forKey: Self.savedVideoViewsKey),
           let views = try? JSONDecoder().decode([SavedVideoView].self, from: data) {
            savedVideoViews = views
            AppLogger.appModel.info("Loaded \(views.count, privacy: .public) saved video views")
        }
    }

    func saveSavedVideoViews() {
        if let data = try? JSONEncoder().encode(savedVideoViews) {
            UserDefaults.standard.set(data, forKey: Self.savedVideoViewsKey)
            let count = savedVideoViews.count
            AppLogger.appModel.info("Saved \(count, privacy: .public) video views")
        }
    }

    func createSavedVideoView(name: String) {
        let view = SavedVideoView(name: name, filter: currentVideoFilter)
        savedVideoViews.append(view)
        saveSavedVideoViews()
    }

    func updateSavedVideoView(_ view: SavedVideoView, with filter: SceneFilterCriteria) {
        if let index = savedVideoViews.firstIndex(where: { $0.id == view.id }) {
            savedVideoViews[index].updateFilter(filter)
            saveSavedVideoViews()
        }
    }

    func deleteSavedVideoView(_ view: SavedVideoView) {
        savedVideoViews.removeAll { $0.id == view.id }
        if selectedSavedVideoView?.id == view.id {
            selectedSavedVideoView = nil
        }
        saveSavedVideoViews()
    }

    func applySavedVideoView(_ view: SavedVideoView) {
        currentVideoFilter = view.filter
        normalizeEmptyMultiSelectModifiers(&currentVideoFilter)
        selectedSavedVideoView = view
        Task {
            await loadInitialVideos()
        }
    }

    func deselectVideoView() {
        currentVideoFilter = SceneFilterCriteria()
        selectedSavedVideoView = nil
        Task {
            await loadInitialVideos()
        }
    }

    func setDefaultVideoView(_ view: SavedVideoView) {
        // Clear any existing default
        for index in savedVideoViews.indices {
            savedVideoViews[index].isDefault = false
        }
        // Set the new default
        if let index = savedVideoViews.firstIndex(where: { $0.id == view.id }) {
            savedVideoViews[index].isDefault = true
        }
        saveSavedVideoViews()
    }

    func clearDefaultVideoView() {
        for index in savedVideoViews.indices {
            savedVideoViews[index].isDefault = false
        }
        saveSavedVideoViews()
    }

    // MARK: - Saved Window Groups Persistence

    var savedWindowGroups: [SavedWindowGroup] = []
    private static let savedWindowGroupsKey = "savedWindowGroups"

    private func loadSavedWindowGroups() {
        if let data = UserDefaults.standard.data(forKey: Self.savedWindowGroupsKey),
           let groups = try? JSONDecoder().decode([SavedWindowGroup].self, from: data) {
            savedWindowGroups = groups
            AppLogger.windowState.info("Loaded \(groups.count, privacy: .public) saved window groups")
        }
    }

    func persistSavedWindowGroups() {
        if let data = try? JSONEncoder().encode(savedWindowGroups) {
            UserDefaults.standard.set(data, forKey: Self.savedWindowGroupsKey)
            let count = savedWindowGroups.count
            AppLogger.windowState.info("Persisted \(count, privacy: .public) saved window groups")
        }
    }

    func saveCurrentWindowGroup(name: String) {
        let images = openPopOutWindows.values.flatMap { $0 }.map(\.image)
        guard !images.isEmpty else { return }
        let group = SavedWindowGroup(name: name, images: images)
        savedWindowGroups.append(group)
        persistSavedWindowGroups()
        AppLogger.windowState.info("Saved window group '\(name, privacy: .public)' with \(images.count, privacy: .public) windows")
    }


    func deleteSavedWindowGroup(_ group: SavedWindowGroup) {
        savedWindowGroups.removeAll { $0.id == group.id }
        persistSavedWindowGroups()
    }

    func renameSavedWindowGroup(_ group: SavedWindowGroup, newName: String) {
        if let index = savedWindowGroups.firstIndex(where: { $0.id == group.id }) {
            savedWindowGroups[index].name = newName
            persistSavedWindowGroups()
        }
    }

    func removeImageFromWindowGroup(_ group: SavedWindowGroup, imageId: UUID) {
        guard let groupIndex = savedWindowGroups.firstIndex(where: { $0.id == group.id }) else { return }
        savedWindowGroups[groupIndex].images.removeAll { $0.id == imageId }
        if savedWindowGroups[groupIndex].images.isEmpty {
            savedWindowGroups.remove(at: groupIndex)
        }
        persistSavedWindowGroups()
        AppLogger.windowState.info("Removed image from window group '\(group.name, privacy: .public)'")
    }

    func addImagesToWindowGroup(_ group: SavedWindowGroup, images: [GalleryImage]) {
        guard let groupIndex = savedWindowGroups.firstIndex(where: { $0.id == group.id }) else { return }
        savedWindowGroups[groupIndex].images.append(contentsOf: images)
        persistSavedWindowGroups()
        let count = images.count
        AppLogger.windowState.info("Added \(count, privacy: .public) images to window group '\(group.name, privacy: .public)'")
    }

    func restoreAllImagesInGroup(_ group: SavedWindowGroup) {
        Task { @MainActor in
            for image in group.images {
                enqueuePhotoWindowOpen(image)
                try? await Task.sleep(for: .seconds(0.3))
            }
            AppLogger.windowState.info("Restored all \(group.images.count, privacy: .public) windows from group '\(group.name, privacy: .public)'")
        }
    }

    func openPopOutImagesNotInGroup(_ group: SavedWindowGroup) -> [GalleryImage] {
        let groupURLs = Set(group.images.map(\.fullSizeURL))
        return openPopOutWindows.values.flatMap { $0 }
            .map(\.image)
            .filter { !groupURLs.contains($0.fullSizeURL) }
    }

    /// Update the image tracked for a pop-out window (called when user navigates prev/next)
    func updatePopOutWindowImage(windowValueId: UUID, oldImageURL: URL, newImage: GalleryImage) {
        let oldKey = oldImageURL.absoluteString
        let newKey = newImage.fullSizeURL.absoluteString

        // Remove from old URL key
        if var values = openPopOutWindows[oldKey] {
            if let index = values.firstIndex(where: { $0.id == windowValueId }) {
                var windowValue = values.remove(at: index)
                windowValue.image = newImage

                // Add under new URL key
                var newValues = openPopOutWindows[newKey] ?? []
                newValues.append(windowValue)
                openPopOutWindows[newKey] = newValues
            }
            if values.isEmpty {
                openPopOutWindows.removeValue(forKey: oldKey)
            } else {
                openPopOutWindows[oldKey] = values
            }
        }
    }

    // MARK: - Default Views Application

    private func applyDefaultViewsOnStartup() {
        // Apply default image view if one exists
        if let defaultImageView = savedViews.first(where: { $0.isDefault }) {
            currentFilter = defaultImageView.filter
            normalizeEmptyMultiSelectModifiers(&currentFilter)
            selectedSavedView = defaultImageView
            AppLogger.appModel.info("Applied default image view: \(defaultImageView.name, privacy: .public)")
        }

        // Apply default video view if one exists
        if let defaultVideoView = savedVideoViews.first(where: { $0.isDefault }) {
            currentVideoFilter = defaultVideoView.filter
            normalizeEmptyMultiSelectModifiers(&currentVideoFilter)
            selectedSavedVideoView = defaultVideoView
            AppLogger.appModel.info("Applied default video view: \(defaultVideoView.name, privacy: .public)")
        }
    }

    private func normalizeEmptyMultiSelectModifiers(_ filter: inout ImageFilterCriteria) {
        if filter.selectedGalleries.isEmpty {
            filter.galleryModifier = .includesAll
        }
        if filter.selectedTags.isEmpty {
            filter.tagModifier = .includesAll
        }
        if filter.selectedStudios.isEmpty {
            filter.studioModifier = .includesAll
        }
        if filter.selectedPerformers.isEmpty {
            filter.performerModifier = .includesAll
        }
    }

    private func normalizeEmptyMultiSelectModifiers(_ filter: inout SceneFilterCriteria) {
        if filter.selectedGalleries.isEmpty {
            filter.galleryModifier = .includesAll
        }
        if filter.selectedTags.isEmpty {
            filter.tagModifier = .includesAll
        }
        if filter.selectedStudios.isEmpty {
            filter.studioModifier = .includesAll
        }
        if filter.selectedPerformers.isEmpty {
            filter.performerModifier = .includesAll
        }
    }

    // MARK: - Settings Backup

    func exportSettingsBackup() async -> SettingsBackup {
        let video3DData = await Video3DSettingsTracker.shared.exportData()
        let imageEnhancementData = await ImageEnhancementTracker.shared.exportData()

        return SettingsBackup(
            version: SettingsBackup.currentVersion,
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            stashServerURL: stashServerURL,
            stashAPIKey: stashAPIKey,
            autoHideDelay: autoHideDelay,
            slideshowDelay: slideshowDelay,
            maxImageResolution: maxImageResolution,
            roundedCorners: roundedCorners,
            openImagesInSeparateWindows: openImagesInSeparateWindows,
            rememberImageEnhancements: rememberImageEnhancements,
            savedViews: savedViews,
            savedVideoViews: savedVideoViews,
            savedWindowGroups: savedWindowGroups,
            video3DSettings: video3DData,
            imageEnhancementConvertedURLs: imageEnhancementData.convertedURLs,
            imageEnhancementLastViewingModes: imageEnhancementData.lastViewingModes
        )
    }

    func importSettingsBackup(_ backup: SettingsBackup) async {
        // Simple settings — only apply if present in backup
        if let v = backup.stashServerURL { stashServerURL = v }
        if let v = backup.stashAPIKey { stashAPIKey = v }
        if let v = backup.autoHideDelay { autoHideDelay = v }
        if let v = backup.slideshowDelay { slideshowDelay = v }
        if let v = backup.maxImageResolution { maxImageResolution = v }
        if let v = backup.roundedCorners { roundedCorners = v }
        if let v = backup.openImagesInSeparateWindows { openImagesInSeparateWindows = v }
        if let v = backup.rememberImageEnhancements { rememberImageEnhancements = v }

        // Complex settings
        if let v = backup.savedViews {
            savedViews = v
            saveSavedViews()
        }
        if let v = backup.savedVideoViews {
            savedVideoViews = v
            saveSavedVideoViews()
        }
        if let v = backup.savedWindowGroups {
            savedWindowGroups = v
            persistSavedWindowGroups()
        }

        // Actor-based trackers
        if let settings = backup.video3DSettings {
            await Video3DSettingsTracker.shared.importData(settings)
        }
        if let urls = backup.imageEnhancementConvertedURLs,
           let modes = backup.imageEnhancementLastViewingModes {
            await ImageEnhancementTracker.shared.importData(
                convertedURLs: urls,
                lastViewingModes: modes
            )
        }

        // Reconnect API client with potentially updated server config
        updateAPIClient()
    }

    // MARK: - API Client Management

    /// Opens the main window only when one isn't already open.
    /// Prevents creating duplicate main gallery windows from pop-out contexts.
    func showMainWindowIfNeeded(openWindow: OpenWindowAction) {
        guard !isMainWindowOpen else {
            AppLogger.app.debug("Main window already open, skipping duplicate open request")
            return
        }
        openWindow(id: "main")
    }

    func updateAPIClient() {
        if !stashServerURL.isEmpty, let url = URL(string: stashServerURL) {
            // Update with Stash server config
            let config = StashServerConfig(
                serverURL: url,
                apiKey: stashAPIKey.isEmpty ? nil : stashAPIKey
            )
            let hasKey = !stashAPIKey.isEmpty
            AppLogger.appModel.info("Updating API client with URL: \(url, privacy: .private), hasAPIKey: \(hasKey, privacy: .public)")
            Task {
                await apiClient.updateConfig(config)
                // Update image source to use Stash
                self.imageSource = GraphQLImageSource(apiClient: self.apiClient)
                await self.reloadAllGalleries()
            }
        } else {
            // No server URL - use example images
            AppLogger.appModel.info("No Stash Server URL configured, using example images")
            self.imageSource = StaticURLImageSource()
            Task {
                await self.reloadAllGalleries()
            }
        }
    }

    private func reloadAllGalleries() async {
        // Reload images if on pictures tab
        galleryLoadGeneration += 1
        currentPage = 0
        hasMorePages = true
        galleryImages.removeAll()
        await loadInitialGallery()
        // Reload videos
        videoLoadGeneration += 1
        currentVideoPage = 0
        hasMoreVideoPages = true
        galleryVideos.removeAll()
        await loadInitialVideos()
    }
    // MARK: - Image Gallery Methods

    /// Load the initial gallery page
    func loadInitialGallery() async {
        // Bump generation so any in-flight loadNextPage from a prior load discards its results
        galleryLoadGeneration += 1

        let sourceType = String(describing: type(of: imageSource))
        AppLogger.appModel.debug("loadInitialGallery called, source: \(sourceType, privacy: .public)")
        // Ensure random sort has a seed for consistent pagination
        if currentFilter.sortField == .random && currentFilter.randomSeed == nil {
            currentFilter.shuffleRandomSort()
        }
        currentPage = 0
        galleryImages = []
        hasMorePages = true
        // Force-reset loading flags so the new load can proceed even if a prior load is in-flight
        isLoadingGallery = false
        await loadNextPage()
    }

    /// Load the next page of gallery images
    func loadNextPage() async {
        guard !isLoadingGallery && hasMorePages else {
            let loading = isLoadingGallery
            let hasMore = hasMorePages
            AppLogger.appModel.debug("loadNextPage skipped - isLoading: \(loading, privacy: .public), hasMore: \(hasMore, privacy: .public)")
            return
        }

        let generation = galleryLoadGeneration
        let page = currentPage
        let sourceTypeName = String(describing: type(of: imageSource))
        AppLogger.appModel.debug("loadNextPage starting, page: \(page, privacy: .public), source: \(sourceTypeName, privacy: .public)")
        isLoadingGallery = true
        defer {
            if generation == galleryLoadGeneration {
                isLoadingGallery = false
            }
        }

        do {
            // Always use filter since we're on Stash server
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: currentFilter)
            // Discard results if a new loadInitialGallery was called while fetching
            guard generation == galleryLoadGeneration else {
                AppLogger.appModel.debug("loadNextPage discarding stale results (generation \(generation, privacy: .public) != \(self.galleryLoadGeneration, privacy: .public))")
                return
            }
            AppLogger.appModel.debug("loadNextPage got \(result.images.count, privacy: .public) images, hasMore: \(result.hasMore, privacy: .public)")
            galleryImages.append(contentsOf: result.images)
            hasMorePages = result.hasMore
            currentPage += 1
        } catch {
            AppLogger.appModel.error("Failed to load gallery page: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Apply current filter and reload gallery
    func applyFilter() async {
        selectedSavedView = nil  // Clear saved view selection when manually filtering
        await loadInitialGallery()
    }

    /// Clear all filters and reload
    func clearFilters() async {
        currentFilter.clearFilters()
        selectedSavedView = nil
        await loadInitialGallery()
    }

    // MARK: - Autocomplete Methods

    /// Search galleries for autocomplete
    func searchGalleries(query: String) async {

        isLoadingGalleries = true
        defer { isLoadingGalleries = false }

        do {
            let result = try await apiClient.findGalleries(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableGalleries = result.galleries.map { gallery in
                // Try title first, then folder path, then first file path, then fallback to ID
                let name: String
                if let title = gallery.title, !title.isEmpty {
                    name = title
                } else if let folderPath = gallery.folder?.path,
                          let lastComponent = folderPath.components(separatedBy: "/").last,
                          !lastComponent.isEmpty {
                    name = lastComponent
                } else if let firstFile = gallery.files?.first,
                          let fileName = firstFile.path.components(separatedBy: "/").last,
                          !fileName.isEmpty {
                    // Use parent directory name from file path
                    let pathComponents = firstFile.path.components(separatedBy: "/")
                    if pathComponents.count >= 2 {
                        name = pathComponents[pathComponents.count - 2]
                    } else {
                        name = fileName
                    }
                } else {
                    name = "Gallery \(gallery.id)"
                }
                return AutocompleteItem(id: gallery.id, name: name)
            }.sorted {
                let name1 = $0.name.lowercased()
                let name2 = $1.name.lowercased()

                let name1IsExactMatch = (name1 == lowercasedQuery)
                let name2IsExactMatch = (name2 == lowercasedQuery)

                if name1IsExactMatch, !name2IsExactMatch { return true }
                if !name1IsExactMatch, name2IsExactMatch { return false }

                let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                if name1HasPrefix, !name2HasPrefix {
                    return true
                } else if !name1HasPrefix, name2HasPrefix {
                    return false
                } else if name1HasPrefix, name2HasPrefix {
                    // Both have prefix match: prioritize shorter names and those without separators
                    let name1HasSeparator = name1.contains("_") || name1.contains("-")
                    let name2HasSeparator = name2.contains("_") || name2.contains("-")
                    if name1HasSeparator != name2HasSeparator {
                        return !name1HasSeparator
                    }
                    // Both have same separator status: sort by length then alphabetically
                    if name1.count != name2.count {
                        return name1.count < name2.count
                    }
                    return name1 < name2
                } else {
                    return name1 < name2
                }
            }
            let galleriesCount = availableGalleries.count
            AppLogger.appModel.debug("Loaded \(galleriesCount, privacy: .public) galleries for autocomplete")
        } catch {
            AppLogger.appModel.error("Failed to search galleries: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search tags for autocomplete
    func searchTags(query: String) async {

        isLoadingTags = true
        defer { isLoadingTags = false }

        do {
            let result = try await apiClient.findTags(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableTags = result.tags.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        // Both have prefix match: prioritize shorter names and those without separators
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        // Both have same separator status: sort by length then alphabetically
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search studios for autocomplete
    func searchStudios(query: String) async {

        isLoadingStudios = true
        defer { isLoadingStudios = false }

        do {
            let result = try await apiClient.findStudios(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availableStudios = result.studios.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search studios: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Search performers for autocomplete
    func searchPerformers(query: String) async {

        isLoadingPerformers = true
        defer { isLoadingPerformers = false }

        do {
            let result = try await apiClient.findPerformers(query: query.isEmpty ? nil : query)
            let lowercasedQuery = query.lowercased()
            availablePerformers = result.performers.map { AutocompleteItem(id: $0.id, name: $0.name) }
                .sorted {
                    let name1 = $0.name.lowercased()
                    let name2 = $1.name.lowercased()

                    let name1IsExactMatch = (name1 == lowercasedQuery)
                    let name2IsExactMatch = (name2 == lowercasedQuery)

                    if name1IsExactMatch, !name2IsExactMatch { return true }
                    if !name1IsExactMatch, name2IsExactMatch { return false }

                    let name1HasPrefix = name1.hasPrefix(lowercasedQuery)
                    let name2HasPrefix = name2.hasPrefix(lowercasedQuery)

                    if name1HasPrefix, !name2HasPrefix {
                        return true
                    } else if !name1HasPrefix, name2HasPrefix {
                        return false
                    } else if name1HasPrefix, name2HasPrefix {
                        let name1HasSeparator = name1.contains("_") || name1.contains("-")
                        let name2HasSeparator = name2.contains("_") || name2.contains("-")
                        if name1HasSeparator != name2HasSeparator {
                            return !name1HasSeparator
                        }
                        if name1.count != name2.count {
                            return name1.count < name2.count
                        }
                        return name1 < name2
                    } else {
                        return name1 < name2
                    }
                }
        } catch {
            AppLogger.appModel.error("Failed to search performers: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load initial autocomplete data
    func loadAutocompleteData() async {
        await searchGalleries(query: "")
        await searchTags(query: "")
        await searchStudios(query: "")
        await searchPerformers(query: "")
    }

    // MARK: - UI Visibility Control

    /// Toggle UI visibility (for tap gesture)
    func toggleUIVisibility() {
        isUIHidden.toggle()
        if !isUIHidden {
            // UI is now visible, start auto-hide timer
            startAutoHideTimer()
        } else {
            // UI is hidden, cancel any pending auto-hide
            cancelAutoHideTimer()
        }
    }

    /// Start the auto-hide timer
    func startAutoHideTimer() {
        cancelAutoHideTimer()
        // If auto-hide is disabled (delay is 0), don't start the timer
        guard autoHideDelay > 0 else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoHideDelay))
            if !Task.isCancelled && isShowingVideoDetail {
                isUIHidden = true
            }
        }
    }

    /// Cancel the auto-hide timer
    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// Reset the auto-hide timer (called on user interaction)
    func resetAutoHideTimer() {
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Video Gallery Methods

    /// Load the initial video gallery page
    func loadInitialVideos() async {
        // Bump generation so any in-flight loadNextVideoPage discards its results
        videoLoadGeneration += 1

        AppLogger.appModel.debug("loadInitialVideos called")
        // Ensure random sort has a seed for consistent pagination
        if currentVideoFilter.sortField == .random && currentVideoFilter.randomSeed == nil {
            currentVideoFilter.shuffleRandomSort()
        }
        currentVideoPage = 0
        galleryVideos = []
        hasMoreVideoPages = true
        // Force-reset loading flags so the new load can proceed even if a prior load is in-flight
        isLoadingVideos = false
        isLoadingVideoViewerPage = false
        await loadNextVideoPage()
    }

    /// Load the next page of videos
    func loadNextVideoPage() async {
        guard !isLoadingVideos && !isLoadingVideoViewerPage && hasMoreVideoPages else {
            let loadingVideos = isLoadingVideos
            let hasMoreVideo = hasMoreVideoPages
            AppLogger.appModel.debug("loadNextVideoPage skipped - isLoading: \(loadingVideos, privacy: .public), hasMore: \(hasMoreVideo, privacy: .public)")
            return
        }

        let generation = videoLoadGeneration
        let videoPage = currentVideoPage
        AppLogger.appModel.debug("loadNextVideoPage starting, page: \(videoPage, privacy: .public)")
        isLoadingVideos = true
        defer {
            if generation == videoLoadGeneration {
                isLoadingVideos = false
            }
        }

        do {
            // Always use filter since we're on Stash server
            let result = try await videoSource.fetchVideos(page: currentVideoPage, pageSize: pageSize, filter: currentVideoFilter)
            // Discard results if a new loadInitialVideos was called while fetching
            guard generation == videoLoadGeneration else {
                AppLogger.appModel.debug("loadNextVideoPage discarding stale results")
                return
            }
            AppLogger.appModel.debug("loadNextVideoPage got \(result.videos.count, privacy: .public) videos, hasMore: \(result.hasMore, privacy: .public)")
            galleryVideos.append(contentsOf: result.videos)
            hasMoreVideoPages = result.hasMore
            currentVideoPage += 1
        } catch {
            AppLogger.appModel.error("Failed to load video page: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load more videos for the viewer using the snapshotted filter
    func loadMoreVideosForViewer() async {
        guard !isLoadingVideos && !isLoadingVideoViewerPage && hasMoreVideoPages else { return }

        let generation = videoLoadGeneration
        isLoadingVideoViewerPage = true
        defer {
            if generation == videoLoadGeneration {
                isLoadingVideoViewerPage = false
            }
        }

        do {
            let result = try await videoSource.fetchVideos(page: currentVideoPage, pageSize: pageSize, filter: viewerVideoFilter)
            guard generation == videoLoadGeneration else { return }
            AppLogger.appModel.debug("Viewer loaded \(result.videos.count, privacy: .public) more videos")
            galleryVideos.append(contentsOf: result.videos)
            hasMoreVideoPages = result.hasMore
            currentVideoPage += 1
        } catch {
            AppLogger.appModel.error("Failed to load viewer video page: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Check if more videos should be loaded based on proximity to end
    private func checkAndLoadMoreVideosIfNeeded(currentIndex: Int) {
        let remaining = galleryVideos.count - currentIndex - 1
        if remaining <= viewerPrefetchThreshold && hasMoreVideoPages && !isLoadingVideos && !isLoadingVideoViewerPage {
            Task {
                await loadMoreVideosForViewer()
            }
        }
    }

    /// Apply current video filter and reload videos
    func applyVideoFilter() async {
        selectedSavedVideoView = nil  // Clear saved video view selection when manually filtering
        await loadInitialVideos()
    }

    /// Clear all video filters and reload
    func clearVideoFilters() async {
        currentVideoFilter.clearFilters()
        selectedSavedVideoView = nil
        await loadInitialVideos()
    }

    /// Select a video to play
    func selectVideoForDetail(_ video: GalleryVideo) {
        selectedVideo = video
        lastViewedVideoId = video.id
        isShowingVideoDetail = true
        videoStereoscopicOverride = nil
        video3DSettings = nil

        // Snapshot the filter on first entry to the viewer
        if viewerVideoFilter == nil {
            viewerVideoFilter = currentVideoFilter
        }
    }

    /// Dismiss video player
    func dismissVideoDetail() {
        isShowingVideoDetail = false
        selectedVideo = nil
        videoStereoscopicOverride = nil
        video3DSettings = nil
        // Clear the snapshotted viewer filter
        viewerVideoFilter = nil
    }

    /// Navigate to next video
    func nextVideo() {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo),
              currentIndex + 1 < galleryVideos.count else { return }

        let nextIndex = currentIndex + 1
        checkAndLoadMoreVideosIfNeeded(currentIndex: nextIndex)
        selectVideoForDetail(galleryVideos[nextIndex])
    }

    /// Navigate to previous video
    func previousVideo() {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo),
              currentIndex > 0 else { return }

        selectVideoForDetail(galleryVideos[currentIndex - 1])
    }

    var hasNextVideo: Bool {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo) else { return false }
        return currentIndex + 1 < galleryVideos.count
    }

    var hasPreviousVideo: Bool {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo) else { return false }
        return currentIndex > 0
    }

    var currentVideoPosition: Int {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo) else { return 0 }
        return currentIndex + 1
    }

    // MARK: - Video Share

    func shareVideo() async {
        guard !isPreparingVideoShare, let video = selectedVideo else { return }
        isPreparingVideoShare = true
        defer { isPreparingVideoShare = false }

        let url = video.streamURL
        let shareName = video.fileName ?? video.title

        if url.isFileURL {
            presentVideoShareSheet(url: ShareSheetHelper.prepareShareFile(from: url, title: shareName, originalURL: url))
            return
        }

        // Remote Stash video — download to temp file
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let namedURL = ShareSheetHelper.prepareShareFile(from: tempURL, title: shareName, originalURL: url)
            try? FileManager.default.removeItem(at: tempURL)
            presentVideoShareSheet(url: namedURL)
        } catch {
            AppLogger.appModel.error("Failed to download video for sharing: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func presentVideoShareSheet(url: URL) {
        cancelAutoHideTimer()
        videoShareFileURL = url
    }

    // MARK: - Rating & O Counter Mutations

    func updateImageRating(stashId: String, rating100: Int?) async throws {
        try await apiClient.updateImageRating(imageId: stashId, rating100: rating100)
        // Update local state
        if var image = selectedImage, image.stashId == stashId {
            image.rating100 = rating100
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].rating100 = rating100
        }
    }

    func updateVideoRating(stashId: String, rating100: Int?) async throws {
        try await apiClient.updateSceneRating(sceneId: stashId, rating100: rating100)
        if var video = selectedVideo, video.stashId == stashId {
            video.rating100 = rating100
            selectedVideo = video
        }
        if let index = galleryVideos.firstIndex(where: { $0.stashId == stashId }) {
            galleryVideos[index].rating100 = rating100
        }
    }

    func incrementImageOCounter(stashId: String) async throws {
        let newValue = try await apiClient.incrementImageOCounter(imageId: stashId)
        if var image = selectedImage, image.stashId == stashId {
            image.oCounter = newValue
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = newValue
        }
    }

    func decrementImageOCounter(stashId: String) async throws {
        let newValue = try await apiClient.decrementImageOCounter(imageId: stashId)
        if var image = selectedImage, image.stashId == stashId {
            image.oCounter = newValue
            selectedImage = image
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = newValue
        }
    }

    func incrementVideoOCounter(stashId: String) async throws {
        let newValue = try await apiClient.incrementSceneOCounter(sceneId: stashId)
        if var video = selectedVideo, video.stashId == stashId {
            video.oCounter = newValue
            selectedVideo = video
        }
        if let index = galleryVideos.firstIndex(where: { $0.stashId == stashId }) {
            galleryVideos[index].oCounter = newValue
        }
    }

    func decrementVideoOCounter(stashId: String) async throws {
        let newValue = try await apiClient.decrementSceneOCounter(sceneId: stashId)
        if var video = selectedVideo, video.stashId == stashId {
            video.oCounter = newValue
            selectedVideo = video
        }
        if let index = galleryVideos.firstIndex(where: { $0.stashId == stashId }) {
            galleryVideos[index].oCounter = newValue
        }
    }

}
