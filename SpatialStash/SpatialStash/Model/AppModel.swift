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

/// Source type for media content
enum MediaSourceType: String, CaseIterable {
    case staticURLs = "Static URLs (Demo)"
    case stashServer = "Stash Server"
    case localFiles = "Local Files"
}

@MainActor
@Observable
class AppModel {
    // MARK: - Navigation State

    var selectedTab: Tab = .pictures
    var isShowingVideoDetail: Bool = false

    /// Tracks the last content tab (pictures or videos) for filter context
    var lastContentTab: Tab = .pictures

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

    var mediaSourceType: MediaSourceType {
        didSet {
            if mediaSourceType != oldValue {
                UserDefaults.standard.set(mediaSourceType.rawValue, forKey: "mediaSourceType")
                let sourceType = mediaSourceType.rawValue
                AppLogger.appModel.notice("Media source changed to: \(sourceType, privacy: .public)")
                rebuildImageSource()
                rebuildVideoSource()
                Task {
                    await reloadAllGalleries()
                }
            }
        }
    }

    // MARK: - API Client

    private var apiClient: StashAPIClient

    // MARK: - Image Gallery State

    var galleryImages: [GalleryImage] = []
    var isLoadingGallery: Bool = false
    var currentPage: Int = 0
    var hasMorePages: Bool = true
    /// Incremented on each loadInitialGallery; stale loadNextPage results are discarded
    private var galleryLoadGeneration: Int = 0

    /// Number of images/videos to fetch per page (configurable in settings)
    var pageSize: Int {
        didSet {
            if pageSize != oldValue {
                UserDefaults.standard.set(pageSize, forKey: "pageSize")
                let size = pageSize
                AppLogger.appModel.info("Page size changed to: \(size, privacy: .public)")
            }
        }
    }

    /// Available page size options for the picker
    static let pageSizeOptions: [Int] = [10, 20, 30, 50, 100]

    // MARK: - Video Gallery State

    var galleryVideos: [GalleryVideo] = []
    var isLoadingVideos: Bool = false
    var currentVideoPage: Int = 0
    var hasMoreVideoPages: Bool = true
    /// Incremented on each loadInitialVideos; stale loadNextVideoPage results are discarded
    private var videoLoadGeneration: Int = 0

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
    var isLoadingGalleries: Bool = false
    var isLoadingTags: Bool = false

    // MARK: - Image Source (stored, rebuilt on config change)

    private(set) var imageSource: any ImageSource

    // MARK: - Video Source (stored, rebuilt on config change)

    private(set) var videoSource: any VideoSource

    /// Rebuild image source when media type changes
    private func rebuildImageSource() {
        let sourceTypeRaw = mediaSourceType.rawValue
        AppLogger.appModel.debug("Rebuilding image source for: \(sourceTypeRaw, privacy: .public)")
        switch mediaSourceType {
        case .staticURLs:
            imageSource = StaticURLImageSource()
        case .stashServer:
            imageSource = GraphQLImageSource(apiClient: apiClient)
        case .localFiles:
            imageSource = LocalImageSource()
        }
    }

    /// Rebuild video source based on media type
    private func rebuildVideoSource() {
        switch mediaSourceType {
        case .localFiles:
            videoSource = LocalVideoSource()
        default:
            videoSource = GraphQLVideoSource(apiClient: apiClient)
        }
    }

    // MARK: - Selected Items for Detail View

    var selectedImage: GalleryImage?
    var selectedVideo: GalleryVideo?

    // MARK: - Scroll Position Tracking

    var lastViewedImageId: UUID?
    var lastViewedVideoId: UUID?

    // MARK: - Main Window Size Tracking

    var mainWindowSize: CGSize = CGSize(width: 1200, height: 800)

    // MARK: - Photo Window Memory Management

    /// Number of currently open pop-out photo windows
    var openPhotoWindowCount: Int = 0

    /// Whether pop-out windows should use lightweight SwiftUI Image display
    /// instead of RealityKit. Activated on memory warning to free GPU resources.
    var useLightweightDisplay: Bool = false

    /// Whether opening another window would exceed the memory budget
    var memoryBudgetExceeded: Bool {
        // Each lightweight 2D window uses ~17 MB
        openPhotoWindowCount >= 40
    }

    /// Whether to show the memory warning alert
    var showMemoryWarningAlert: Bool = false


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
        let defaultPageSize = 20
        let defaultAutoHideDelay: TimeInterval = 3.0
        let defaultSlideshowDelay: TimeInterval = 5.0

        let loadedServerURL = UserDefaults.standard.string(forKey: "stashServerURL") ?? defaultServerURL
        let loadedAPIKey = UserDefaults.standard.string(forKey: "stashAPIKey") ?? defaultAPIKey
        let loadedSourceType: MediaSourceType
        if let savedSourceType = UserDefaults.standard.string(forKey: "mediaSourceType"),
           let sourceType = MediaSourceType(rawValue: savedSourceType) {
            loadedSourceType = sourceType
        } else {
            loadedSourceType = .staticURLs
        }

        // Load page size (with validation)
        let savedPageSize = UserDefaults.standard.integer(forKey: "pageSize")
        let loadedPageSize = savedPageSize > 0 ? savedPageSize : defaultPageSize

        // Load auto-hide delay (0 means disabled, use default if not set)
        let savedAutoHideDelay = UserDefaults.standard.double(forKey: "autoHideDelay")
        let loadedAutoHideDelay = UserDefaults.standard.object(forKey: "autoHideDelay") != nil ? savedAutoHideDelay : defaultAutoHideDelay

        // Load slideshow delay
        let savedSlideshowDelay = UserDefaults.standard.double(forKey: "slideshowDelay")
        let loadedSlideshowDelay = UserDefaults.standard.object(forKey: "slideshowDelay") != nil ? savedSlideshowDelay : defaultSlideshowDelay

        // Initialize stored properties
        self.stashServerURL = loadedServerURL
        self.stashAPIKey = loadedAPIKey
        self.mediaSourceType = loadedSourceType
        self.pageSize = loadedPageSize
        self.autoHideDelay = loadedAutoHideDelay
        self.slideshowDelay = loadedSlideshowDelay

        // Initialize API client with config
        let initialConfig: StashServerConfig
        if let url = URL(string: loadedServerURL) {
            initialConfig = StashServerConfig(
                serverURL: url,
                apiKey: loadedAPIKey.isEmpty ? nil : loadedAPIKey
            )
        } else {
            initialConfig = StashServerConfig.default
        }
        let client = StashAPIClient(config: initialConfig)
        self.apiClient = client

        // Initialize image source based on media source type
        switch loadedSourceType {
        case .staticURLs:
            self.imageSource = StaticURLImageSource()
        case .stashServer:
            self.imageSource = GraphQLImageSource(apiClient: client)
        case .localFiles:
            self.imageSource = LocalImageSource()
        }

        // Initialize video source based on media source type
        switch loadedSourceType {
        case .localFiles:
            self.videoSource = LocalVideoSource()
        default:
            self.videoSource = GraphQLVideoSource(apiClient: client)
        }

        // Now all stored properties are initialized, we can use self
        AppLogger.appModel.info("Init - Server URL: \(self.stashServerURL, privacy: .private)")
        AppLogger.appModel.info("Init - Has API Key: \(!self.stashAPIKey.isEmpty, privacy: .public)")
        AppLogger.appModel.info("Init - Media Source: \(self.mediaSourceType.rawValue, privacy: .public)")
        AppLogger.appModel.info("Init - Page Size: \(self.pageSize, privacy: .public)")
        AppLogger.appModel.info("Init - Image source: \(String(describing: type(of: self.imageSource)), privacy: .public)")

        // Load saved views from UserDefaults
        loadSavedViews()
        loadSavedVideoViews()

        // Apply default views on startup
        applyDefaultViewsOnStartup()

        // Monitor memory pressure and clear caches when warned
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLogger.appModel.warning("Memory warning received — activating lightweight display and clearing caches")
            Task { @MainActor [weak self] in
                await ImageLoader.shared.clearMemoryCache()
                // Switch all photo windows to lightweight mode
                self?.useLightweightDisplay = true
            }
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

    // MARK: - Default Views Application

    private func applyDefaultViewsOnStartup() {
        // Apply default image view if one exists
        if let defaultImageView = savedViews.first(where: { $0.isDefault }) {
            currentFilter = defaultImageView.filter
            selectedSavedView = defaultImageView
            AppLogger.appModel.info("Applied default image view: \(defaultImageView.name, privacy: .public)")
        }

        // Apply default video view if one exists
        if let defaultVideoView = savedVideoViews.first(where: { $0.isDefault }) {
            currentVideoFilter = defaultVideoView.filter
            selectedSavedVideoView = defaultVideoView
            AppLogger.appModel.info("Applied default video view: \(defaultVideoView.name, privacy: .public)")
        }
    }

    // MARK: - API Client Management

    func updateAPIClient() {
        guard let url = URL(string: stashServerURL) else {
            let serverURL = stashServerURL
            AppLogger.appModel.warning("Invalid server URL: \(serverURL, privacy: .private)")
            return
        }
        let config = StashServerConfig(
            serverURL: url,
            apiKey: stashAPIKey.isEmpty ? nil : stashAPIKey
        )
        let hasKey = !stashAPIKey.isEmpty
        AppLogger.appModel.info("Updating API client with URL: \(url, privacy: .private), hasAPIKey: \(hasKey, privacy: .public)")
        Task {
            await apiClient.updateConfig(config)
            // Rebuild sources with updated client
            rebuildImageSource()
            rebuildVideoSource()
        }
    }

    private func reloadAllGalleries() async {
        // Reload images if on pictures tab
        await loadInitialGallery()
        // Reload videos
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
            // Use filter if we're on Stash server, otherwise ignore
            let filter: ImageFilterCriteria? = (mediaSourceType == .stashServer) ? currentFilter : nil
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: filter)
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
        guard mediaSourceType == .stashServer else { return }

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
        guard mediaSourceType == .stashServer else { return }

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

    /// Load initial galleries and tags for autocomplete
    func loadAutocompleteData() async {
        await searchGalleries(query: "")
        await searchTags(query: "")
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
            // Use filter if we're on Stash server, otherwise ignore
            let filter: SceneFilterCriteria? = (mediaSourceType == .stashServer) ? currentVideoFilter : nil
            let result = try await videoSource.fetchVideos(page: currentVideoPage, pageSize: pageSize, filter: filter)
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
            viewerVideoFilter = (mediaSourceType == .stashServer) ? currentVideoFilter : nil
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
