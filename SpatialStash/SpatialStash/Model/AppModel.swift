/*
 Spatial Stash - App Model

 The main model containing observable data used across the views.
 Includes navigation state, gallery management, and spatial image handling.
 */

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
    var isShowingDetailView: Bool = false
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
                print("[AppModel] Media source changed to: \(mediaSourceType.rawValue)")
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

    /// Number of images/videos to fetch per page (configurable in settings)
    var pageSize: Int {
        didSet {
            if pageSize != oldValue {
                UserDefaults.standard.set(pageSize, forKey: "pageSize")
                print("[AppModel] Page size changed to: \(pageSize)")
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

    // MARK: - Stereoscopic Video Immersive State

    /// Whether the stereoscopic video immersive space is currently shown
    var isStereoscopicImmersiveSpaceShown: Bool = false

    /// The video currently being played in immersive mode
    var immersiveVideo: GalleryVideo?

    /// URL of the converted MV-HEVC file for immersive playback
    var immersiveVideoURL: URL?

    /// Override for stereoscopic video viewing mode: nil = auto (stereo for 3D content), false = force mono (left eye only)
    var videoStereoscopicOverride: Bool? = nil

    // MARK: - Filter State

    var currentFilter: ImageFilterCriteria = ImageFilterCriteria()
    var currentVideoFilter: SceneFilterCriteria = SceneFilterCriteria()
    var savedViews: [SavedView] = []
    var selectedSavedView: SavedView?

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
        print("[AppModel] Rebuilding image source for: \(mediaSourceType.rawValue)")
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

    // MARK: - Bundled Images (Legacy - kept for reference)

    let imageNames: [String] = [
        "architecture-windmill-tulips",
        "food-lemon-tree",
        "animals-cat-sleeping-in-ruins",
        "animals-bee-on-purple-flower",
        "architecture-hampi-india"
    ]

    var bundledImageURLs: [URL] {
        var urls: [URL] = []
        for imageName in imageNames {
            guard let imageURL = Bundle.main.url(forResource: imageName, withExtension: ".jpeg") else {
                print("Unable to find image \(imageName) in bundle.")
                continue
            }
            urls.append(imageURL)
        }
        return urls
    }

    // MARK: - Spatial Image State (Existing)

    var imageIndex: Int = 0
    var imageURL: URL? = nil
    var imageAspectRatio: CGFloat = 1.0
    var contentEntity: Entity = Entity()
    var spatial3DImageState: Spatial3DImageState = .notGenerated
    var spatial3DImage: ImagePresentationComponent.Spatial3DImage? = nil
    var isLoadingDetailImage: Bool = false

    // MARK: - GIF Support

    var isAnimatedGIF: Bool = false
    var currentImageData: Data? = nil

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

    // MARK: - Initialization

    init() {
        // Load persisted settings or use defaults (use local vars to avoid self reference issues)
        let defaultServerURL = ""
        let defaultAPIKey = ""
        let defaultPageSize = 20
        let defaultAutoHideDelay: TimeInterval = 3.0

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

        // Initialize stored properties
        self.stashServerURL = loadedServerURL
        self.stashAPIKey = loadedAPIKey
        self.mediaSourceType = loadedSourceType
        self.pageSize = loadedPageSize
        self.autoHideDelay = loadedAutoHideDelay

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
        print("[AppModel] Init - Server URL: \(self.stashServerURL)")
        print("[AppModel] Init - Has API Key: \(!self.stashAPIKey.isEmpty)")
        print("[AppModel] Init - Media Source: \(self.mediaSourceType.rawValue)")
        print("[AppModel] Init - Page Size: \(self.pageSize)")
        print("[AppModel] Init - Image source: \(type(of: self.imageSource))")

        // Set initial image URL from bundled images (fallback)
        if let firstBundled = bundledImageURLs.first {
            imageURL = firstBundled
        }

        // Load saved views from UserDefaults
        loadSavedViews()
    }

    // MARK: - Saved Views Persistence

    private static let savedViewsKey = "savedViews"

    private func loadSavedViews() {
        if let data = UserDefaults.standard.data(forKey: Self.savedViewsKey),
           let views = try? JSONDecoder().decode([SavedView].self, from: data) {
            savedViews = views
            print("[AppModel] Loaded \(views.count) saved views")
        }
    }

    func saveSavedViews() {
        if let data = try? JSONEncoder().encode(savedViews) {
            UserDefaults.standard.set(data, forKey: Self.savedViewsKey)
            print("[AppModel] Saved \(savedViews.count) views")
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

    // MARK: - API Client Management

    func updateAPIClient() {
        guard let url = URL(string: stashServerURL) else {
            print("[AppModel] Invalid server URL: \(stashServerURL)")
            return
        }
        let config = StashServerConfig(
            serverURL: url,
            apiKey: stashAPIKey.isEmpty ? nil : stashAPIKey
        )
        print("[AppModel] Updating API client with URL: \(url), hasAPIKey: \(!stashAPIKey.isEmpty)")
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
        print("[AppModel] loadInitialGallery called, source: \(type(of: imageSource))")
        currentPage = 0
        galleryImages = []
        hasMorePages = true
        await loadNextPage()
    }

    /// Load the next page of gallery images
    func loadNextPage() async {
        guard !isLoadingGallery && hasMorePages else {
            print("[AppModel] loadNextPage skipped - isLoading: \(isLoadingGallery), hasMore: \(hasMorePages)")
            return
        }

        print("[AppModel] loadNextPage starting, page: \(currentPage), source: \(type(of: imageSource))")
        isLoadingGallery = true
        defer { isLoadingGallery = false }

        do {
            // Use filter if we're on Stash server, otherwise ignore
            let filter: ImageFilterCriteria? = (mediaSourceType == .stashServer) ? currentFilter : nil
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: filter)
            print("[AppModel] loadNextPage got \(result.images.count) images, hasMore: \(result.hasMore)")
            galleryImages.append(contentsOf: result.images)
            hasMorePages = result.hasMore
            currentPage += 1
        } catch {
            print("[AppModel] Failed to load gallery page: \(error)")
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
            }
            print("[AppModel] Loaded \(availableGalleries.count) galleries for autocomplete")
        } catch {
            print("[AppModel] Failed to search galleries: \(error)")
        }
    }

    /// Search tags for autocomplete
    func searchTags(query: String) async {
        guard mediaSourceType == .stashServer else { return }

        isLoadingTags = true
        defer { isLoadingTags = false }

        do {
            let result = try await apiClient.findTags(query: query.isEmpty ? nil : query)
            availableTags = result.tags.map { AutocompleteItem(id: $0.id, name: $0.name) }
        } catch {
            print("[AppModel] Failed to search tags: \(error)")
        }
    }

    /// Load initial galleries and tags for autocomplete
    func loadAutocompleteData() async {
        await searchGalleries(query: "")
        await searchTags(query: "")
    }

    /// Select an image from the gallery to view in detail
    func selectImageForDetail(_ image: GalleryImage) {
        selectedImage = image
        lastViewedImageId = image.id
        imageURL = image.fullSizeURL
        isShowingDetailView = true
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        isAnimatedGIF = false
        currentImageData = nil
        isLoadingDetailImage = true
        // Reset content entity to clear previous image
        contentEntity.components.remove(ImagePresentationComponent.self)

        // Load image data to detect if it's a GIF
        Task {
            await loadImageDataForDetail(url: image.fullSizeURL)
        }
    }

    /// Load image data for the detail view and detect if it's an animated GIF
    private func loadImageDataForDetail(url: URL) async {
        do {
            if let data = try await ImageLoader.shared.loadImageData(from: url) {
                currentImageData = data
                isAnimatedGIF = data.isAnimatedGIF

                if isAnimatedGIF {
                    // For GIFs, calculate aspect ratio from the image data
                    if let image = UIImage(data: data) {
                        imageAspectRatio = image.size.width / image.size.height
                    }
                    isLoadingDetailImage = false
                }
            }
        } catch {
            print("[AppModel] Failed to load image data: \(error)")
        }
    }

    /// Dismiss the detail view and return to gallery
    func dismissDetailView() {
        isShowingDetailView = false
        selectedImage = nil
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        // Reset UI visibility when leaving detail view
        cancelAutoHideTimer()
        isUIHidden = false
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
            if !Task.isCancelled && (isShowingDetailView || isShowingVideoDetail) && !isLoadingDetailImage {
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

    /// Navigate to next image in gallery while in detail view
    func nextImage() {
        guard let currentImage = selectedImage,
              let currentIndex = galleryImages.firstIndex(of: currentImage),
              currentIndex + 1 < galleryImages.count else { return }

        selectImageForDetail(galleryImages[currentIndex + 1])
    }

    /// Navigate to previous image in gallery while in detail view
    func previousImage() {
        guard let currentImage = selectedImage,
              let currentIndex = galleryImages.firstIndex(of: currentImage),
              currentIndex > 0 else { return }

        selectImageForDetail(galleryImages[currentIndex - 1])
    }

    /// Check if there's a next image available
    var hasNextImage: Bool {
        guard let currentImage = selectedImage,
              let currentIndex = galleryImages.firstIndex(of: currentImage) else { return false }
        return currentIndex + 1 < galleryImages.count
    }

    /// Check if there's a previous image available
    var hasPreviousImage: Bool {
        guard let currentImage = selectedImage,
              let currentIndex = galleryImages.firstIndex(of: currentImage) else { return false }
        return currentIndex > 0
    }

    /// Current image position (1-indexed) for display
    var currentImagePosition: Int {
        guard let currentImage = selectedImage,
              let currentIndex = galleryImages.firstIndex(of: currentImage) else { return 0 }
        return currentIndex + 1
    }

    // MARK: - Video Gallery Methods

    /// Load the initial video gallery page
    func loadInitialVideos() async {
        print("[AppModel] loadInitialVideos called")
        currentVideoPage = 0
        galleryVideos = []
        hasMoreVideoPages = true
        await loadNextVideoPage()
    }

    /// Load the next page of videos
    func loadNextVideoPage() async {
        guard !isLoadingVideos && hasMoreVideoPages else {
            print("[AppModel] loadNextVideoPage skipped - isLoading: \(isLoadingVideos), hasMore: \(hasMoreVideoPages)")
            return
        }

        print("[AppModel] loadNextVideoPage starting, page: \(currentVideoPage)")
        isLoadingVideos = true
        defer { isLoadingVideos = false }

        do {
            // Use filter if we're on Stash server, otherwise ignore
            let filter: SceneFilterCriteria? = (mediaSourceType == .stashServer) ? currentVideoFilter : nil
            let result = try await videoSource.fetchVideos(page: currentVideoPage, pageSize: pageSize, filter: filter)
            print("[AppModel] loadNextVideoPage got \(result.videos.count) videos, hasMore: \(result.hasMore)")
            galleryVideos.append(contentsOf: result.videos)
            hasMoreVideoPages = result.hasMore
            currentVideoPage += 1
        } catch {
            print("[AppModel] Failed to load video page: \(error)")
        }
    }

    /// Apply current video filter and reload videos
    func applyVideoFilter() async {
        selectedSavedView = nil  // Clear saved view selection when manually filtering
        await loadInitialVideos()
    }

    /// Clear all video filters and reload
    func clearVideoFilters() async {
        currentVideoFilter.clearFilters()
        selectedSavedView = nil
        await loadInitialVideos()
    }

    /// Select a video to play
    func selectVideoForDetail(_ video: GalleryVideo) {
        selectedVideo = video
        lastViewedVideoId = video.id
        isShowingVideoDetail = true
        videoStereoscopicOverride = nil
    }

    /// Dismiss video player
    func dismissVideoDetail() {
        isShowingVideoDetail = false
        selectedVideo = nil
        videoStereoscopicOverride = nil
    }

    /// Navigate to next video
    func nextVideo() {
        guard let currentVideo = selectedVideo,
              let currentIndex = galleryVideos.firstIndex(of: currentVideo),
              currentIndex + 1 < galleryVideos.count else { return }

        selectVideoForDetail(galleryVideos[currentIndex + 1])
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

    // MARK: - Spatial Image Methods (Existing - Preserved)

    func createImagePresentationComponent() async {
        guard let imageURL else {
            print("ImageURL is nil.")
            isLoadingDetailImage = false
            return
        }
        isLoadingDetailImage = true
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        do {
            // Prefer cached file URL to avoid network when reopening
            let sourceURL: URL
            if !imageURL.isFileURL, let cached = await DiskImageCache.shared.cachedFileURL(for: imageURL) {
                sourceURL = cached
            } else {
                sourceURL = imageURL
            }
            spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(contentsOf: sourceURL)
        } catch {
            print("Unable to initialize spatial 3D image: \(error.localizedDescription)")
            isLoadingDetailImage = false

            // Enhanced error handling for network scenarios
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    print("No internet connection available.")
                case .timedOut:
                    print("Request timed out.")
                case .cannotFindHost:
                    print("Cannot find host.")
                default:
                    print("URL error: \(urlError.code)")
                }
            }
            return
        }

        guard let spatial3DImage else {
            print("Spatial3DImage is nil.")
            isLoadingDetailImage = false
            return
        }

        let imagePresentationComponent = ImagePresentationComponent(spatial3DImage: spatial3DImage)
        contentEntity.components.set(imagePresentationComponent)
        if let aspectRatio = imagePresentationComponent.aspectRatio(for: .mono) {
            imageAspectRatio = CGFloat(aspectRatio)
        }
        isLoadingDetailImage = false

        // Auto-generate spatial 3D if this image was previously converted
        await autoGenerateSpatial3DIfPreviouslyConverted()
    }

    func generateSpatial3DImage() async throws {
        guard spatial3DImageState == .notGenerated else {
            print("Spatial 3D image already generated or generation is in progress.")
            return
        }
        guard let spatial3DImage else {
            print("createImagePresentationComponent.")
            return
        }
        guard var imagePresentationComponent = contentEntity.components[ImagePresentationComponent.self] else {
            print("ImagePresentationComponent is missing from the entity.")
            return
        }
        // Set the desired viewing mode before generating so that it will trigger the
        // generation animation.
        imagePresentationComponent.desiredViewingMode = .spatial3D
        contentEntity.components.set(imagePresentationComponent)

        // Generate the Spatial3DImage scene.
        spatial3DImageState = .generating
        try await spatial3DImage.generate()
        spatial3DImageState = .generated

        // Track that this image was converted
        if let url = imageURL {
            await Spatial3DConversionTracker.shared.markAsConverted(url: url)
            await Spatial3DConversionTracker.shared.setLastViewingMode(url: url, mode: .spatial3D)
        }

        if let aspectRatio = imagePresentationComponent.aspectRatio(for: .spatial3D) {
            imageAspectRatio = CGFloat(aspectRatio)
        }
    }

    /// Check if the current image was previously converted and auto-generate if so
    private func autoGenerateSpatial3DIfPreviouslyConverted() async {
        guard let url = imageURL,
              !isAnimatedGIF,
              spatial3DImageState == .notGenerated else {
            return
        }

        // Respect the user's last-used mode for this image
        if let lastMode = await Spatial3DConversionTracker.shared.lastViewingMode(url: url), lastMode == .mono {
            print("[AppModel] Skipping auto-generation; last mode was 2D")
            return
        }

        let wasConverted = await Spatial3DConversionTracker.shared.wasConverted(url: url)
        if wasConverted {
            print("[AppModel] Auto-generating spatial 3D for previously converted image")
            do {
                try await generateSpatial3DImage()
            } catch {
                print("[AppModel] Auto-generation failed: \(error)")
            }
        }
    }
}
