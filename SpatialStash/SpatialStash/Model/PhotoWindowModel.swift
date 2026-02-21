/*
 Spatial Stash - Photo Window Model

 Per-window model for individual photo display windows.
 Each photo window gets its own instance with independent state.

 Memory strategy: Windows open in lightweight 2D mode using a downsampled
 UIImage via SwiftUI Image. RealityKit (full resolution) is only loaded when
 the user explicitly activates 3D. On window resize, the 2D display image
 is re-downsampled in memory (no temp files on disk).
 */

import os
import RealityKit
import SwiftUI

@MainActor
@Observable
class PhotoWindowModel {
    // MARK: - Window-specific Image State

    var image: GalleryImage
    var imageURL: URL
    var imageAspectRatio: CGFloat = 1.0
    var contentEntity: Entity = Entity()
    var spatial3DImageState: Spatial3DImageState = .notGenerated
    var spatial3DImage: ImagePresentationComponent.Spatial3DImage? = nil
    var isLoadingDetailImage: Bool = false
    var inputPlaneEntity: Entity = Entity()

    // MARK: - 2D Display Image State

    /// Downsampled UIImage for lightweight 2D display (nil when in 3D mode)
    var displayImage: UIImage? = nil

    /// Whether the window is showing the RealityKit 3D view
    var is3DMode: Bool = false

    /// Set when user taps "Generate 3D" from 2D mode — the RealityView
    /// init closure will consume this flag and start generation.
    var pendingGenerate3D: Bool = false

    /// Native image dimensions (read from file metadata without decoding)
    private var nativeImageDimensions: CGSize?

    /// The max dimension used for the current displayImage
    private var currentDisplayMaxDimension: CGFloat = 0

    /// Last known window size for resize-triggered reloads
    private var lastWindowSize: CGSize?

    /// Debounce task for window resize
    private var resizeDebounceTask: Task<Void, Never>?

    /// Whether a display image load is currently in progress (prevents concurrent loads)
    private var isLoadingDisplayImage: Bool = false

    /// Task for 3D generation (tracked so cleanup can avoid removing the component mid-generation)
    private var generateTask: Task<Void, Never>?

    /// Scale factor for converting window points to texture pixels
    /// (visionOS rendering density + headroom)
    private static let displayScaleFactor: CGFloat = 2.5

    // MARK: - GIF Support

    var isAnimatedGIF: Bool = false
    var currentImageData: Data? = nil

    // MARK: - UI Visibility State

    var isUIHidden: Bool = false
    private var autoHideTask: Task<Void, Never>?

    // MARK: - Slideshow State

    var isSlideshowActive: Bool = false
    var slideshowImages: [GalleryImage] = []
    var slideshowIndex: Int = 0
    private var slideshowTask: Task<Void, Never>?
    private var slideshowHistory: [GalleryImage] = []

    // MARK: - Gallery Navigation State

    /// Snapshot of gallery images when this window was opened
    private var galleryImages: [GalleryImage] = []

    /// Current index in the gallery
    private var currentGalleryIndex: Int = 0

    // MARK: - Lazy Loading State

    /// Image source for loading more pages
    private let imageSource: any ImageSource

    /// Snapshotted filter from when the window was opened
    private let snapshotFilter: ImageFilterCriteria?

    /// Current page for this window's pagination
    private var currentPage: Int

    /// Whether there are more pages to load
    private var hasMorePages: Bool

    /// Page size for pagination
    private let pageSize: Int

    /// Whether a page load is in progress
    private(set) var isLoadingMoreImages: Bool = false

    /// How close to the end of the loaded set before triggering a load
    private let prefetchThreshold: Int = 5

    // MARK: - Shared References

    var appModel: AppModel

    // MARK: - Initialization

    init(image: GalleryImage, appModel: AppModel) {
        self.image = image
        self.imageURL = image.fullSizeURL
        self.appModel = appModel
        self.isLoadingDetailImage = true

        // Capture pagination state for lazy loading (must be before galleryImages access)
        self.imageSource = appModel.imageSource
        self.snapshotFilter = (appModel.mediaSourceType == .stashServer) ? appModel.currentFilter : nil
        self.currentPage = appModel.currentPage
        self.hasMorePages = appModel.hasMorePages
        self.pageSize = appModel.pageSize

        // Capture snapshot of gallery images for navigation
        self.galleryImages = appModel.galleryImages
        self.currentGalleryIndex = galleryImages.firstIndex(of: image) ?? 0

        appModel.openPhotoWindowCount += 1

        // Load image data to detect if it's a GIF
        Task {
            await loadImageDataForDetail(url: image.fullSizeURL)
        }
    }

    // MARK: - Image Loading

    /// Load image data for the detail view and detect if it's an animated GIF
    private func loadImageDataForDetail(url: URL) async {
        do {
            if let data = try await ImageLoader.shared.loadRawData(from: url) {
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
            AppLogger.photoWindow.error("Error loading image data: \(error.localizedDescription, privacy: .public)")
            isLoadingDetailImage = false
        }
    }

    // MARK: - 2D Display Image Loading

    /// Load a downsampled display image sized appropriately for the given window size.
    /// Uses CGImageSource for memory-efficient downsampling without loading
    /// the full image into memory. No temp files are written to disk.
    func loadDisplayImage(for windowSize: CGSize) async {
        guard !isAnimatedGIF else { return }
        guard !is3DMode else { return }
        guard !isLoadingDisplayImage else { return }

        isLoadingDisplayImage = true
        defer { isLoadingDisplayImage = false }

        lastWindowSize = windowSize

        // Ensure raw data is downloaded to disk cache
        if currentImageData == nil {
            await loadImageDataForDetail(url: imageURL)
        }
        guard !isAnimatedGIF else { return }

        // Resolve source file URL (prefer disk cache, fall back to original URL)
        guard let sourceURL = await resolveSourceFileURL() else {
            AppLogger.photoWindow.error("No source file available for display image")
            isLoadingDetailImage = false
            return
        }

        // Read native dimensions from file metadata (no decode)
        if nativeImageDimensions == nil {
            nativeImageDimensions = ThumbnailGenerator.shared.getImageDimensions(for: sourceURL)
        }

        let nativeMaxDim = max(nativeImageDimensions?.width ?? 8192, nativeImageDimensions?.height ?? 8192)

        // Calculate target dimension: window size × scale factor, capped at native
        let targetDimension = min(
            max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
            nativeMaxDim
        )

        // Skip if already loaded at a similar resolution (within 20%)
        if displayImage != nil, currentDisplayMaxDimension > 0 {
            let ratio = targetDimension / currentDisplayMaxDimension
            if ratio > 0.8 && ratio < 1.2 {
                return
            }
        }

        // Downsample off main thread to avoid blocking UI
        let image = await Task.detached { [sourceURL, targetDimension] in
            ThumbnailGenerator.shared.downsampleImage(at: sourceURL, maxDimension: targetDimension)
        }.value

        guard let image else {
            AppLogger.photoWindow.warning("Failed to downsample image for display")
            isLoadingDetailImage = false
            return
        }

        displayImage = image
        imageAspectRatio = image.size.width / image.size.height
        currentDisplayMaxDimension = targetDimension
        isLoadingDetailImage = false
    }

    /// Handle window resize with 1-second debounce. Re-downsamples the display
    /// image in memory when the window size changes significantly.
    func handleWindowResize(_ newSize: CGSize) {
        guard !is3DMode, !isAnimatedGIF else { return }
        guard !isLoadingDetailImage, !isLoadingDisplayImage else { return }
        guard displayImage != nil else { return }

        lastWindowSize = newSize
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            await self.loadDisplayImage(for: newSize)
        }
    }

    /// Resolve the file URL for the current image (disk cache or original file URL)
    private func resolveSourceFileURL() async -> URL? {
        if imageURL.isFileURL {
            return imageURL
        }
        return await DiskImageCache.shared.cachedFileURL(for: imageURL)
    }

    // MARK: - 3D Mode Activation

    /// Activate RealityKit 3D mode. Loads the full-resolution ImagePresentationComponent
    /// from the disk cache and releases the lightweight 2D display image.
    /// - Parameter generateImmediately: If true, RealityView will generate the 3D depth map
    ///   right after creating the component (used when the user explicitly taps "Generate 3D").
    func activate3DMode(generateImmediately: Bool = false) {
        guard !isAnimatedGIF, !is3DMode else { return }
        is3DMode = true
        isLoadingDetailImage = true
        pendingGenerate3D = generateImmediately
        // RealityView's init closure will call createImagePresentationComponent()
    }

    /// Deactivate 3D mode and return to lightweight 2D display.
    func deactivate3DMode() async {
        guard is3DMode else { return }

        // If generation is in progress, we MUST wait for it to finish before
        // removing ImagePresentationComponent. RealityKit's generate() ignores
        // Swift cooperative cancellation and crashes if the component is removed
        // while its internal progress callback is still firing.
        if let task = generateTask {
            task.cancel()
            await task.value  // Wait for generate() to actually finish
            generateTask = nil
        }

        // Release 3D resources — safe now that generate() has completed
        spatial3DImage = nil
        spatial3DImageState = .notGenerated
        pendingGenerate3D = false
        contentEntity.components.remove(ImagePresentationComponent.self)

        is3DMode = false

        // Reset display dimension so the 2D reload doesn't early-exit
        currentDisplayMaxDimension = 0

        // Reload 2D display image
        if let windowSize = lastWindowSize {
            isLoadingDetailImage = true
            await loadDisplayImage(for: windowSize)
        }
    }

    // MARK: - Image Presentation Component

    /// Create the ImagePresentationComponent for the current image (3D mode only).
    /// Loads at full resolution from the disk cache.
    func createImagePresentationComponent() async {
        // Reset state
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        contentEntity.components.remove(ImagePresentationComponent.self)
        inputPlaneEntity = Entity()

        guard !isAnimatedGIF else {
            isLoadingDetailImage = false
            return
        }

        isLoadingDetailImage = true

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
            AppLogger.photoWindow.error("Unable to initialize spatial 3D image: \(error.localizedDescription, privacy: .public)")
            isLoadingDetailImage = false

            // Enhanced error handling for network scenarios
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    AppLogger.photoWindow.error("No internet connection available.")
                case .timedOut:
                    AppLogger.photoWindow.error("Request timed out.")
                case .cannotFindHost:
                    AppLogger.photoWindow.error("Cannot find host.")
                default:
                    AppLogger.photoWindow.error("URL error code: \(urlError.code.rawValue, privacy: .public)")
                }
            }
            return
        }

        guard let spatial3DImage else {
            AppLogger.photoWindow.warning("Spatial3DImage is nil.")
            isLoadingDetailImage = false
            return
        }

        let imagePresentationComponent = ImagePresentationComponent(spatial3DImage: spatial3DImage)
        contentEntity.components.set(imagePresentationComponent)
        if let aspectRatio = imagePresentationComponent.aspectRatio(for: .mono) {
            imageAspectRatio = CGFloat(aspectRatio)
        }

        // Release 2D display image since RealityKit is rendering now
        displayImage = nil

        isLoadingDetailImage = false
        // Note: Auto-generation is handled by PhotoWindowView after entity is added to scene
    }

    /// Called after the entity is added to the RealityKit scene to auto-generate spatial 3D
    func autoGenerateSpatial3DIfNeeded() async {
        await autoGenerateSpatial3DIfPreviouslyConverted()
    }

    // MARK: - Input Plane

    func ensureInputPlaneReady() {
        guard inputPlaneEntity.components[InputTargetComponent.self] == nil else { return }

        inputPlaneEntity = Entity()
        inputPlaneEntity.components.set(InputTargetComponent())
        inputPlaneEntity.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: SIMD3<Float>(1.0, 1.0, 0.01))],
                mode: .default,
                filter: .default
            )
        )
    }

    // MARK: - 3D Generation

    /// Generate spatial 3D image (depth map)
    func generateSpatial3DImage() async {
        // If not in 3D mode yet, activate it first and let the RealityView
        // handle creation + generation after its init closure runs
        if !is3DMode {
            activate3DMode(generateImmediately: true)
            return
        }

        guard spatial3DImageState == .notGenerated else { return }
        guard let spatial3DImage else {
            AppLogger.photoWindow.warning("spatial3DImage is nil, cannot generate")
            return
        }
        guard var imagePresentationComponent = contentEntity.components[ImagePresentationComponent.self] else {
            AppLogger.photoWindow.warning("ImagePresentationComponent is missing from the entity.")
            return
        }

        // Set the desired viewing mode before generating so that it will trigger the
        // generation animation.
        imagePresentationComponent.desiredViewingMode = .spatial3D
        contentEntity.components.set(imagePresentationComponent)

        spatial3DImageState = .generating

        // Track the generation task so cleanup can wait for it
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Generate the Spatial3DImage scene.
                try await spatial3DImage.generate()

                // Check if cancelled (window closed during generation)
                guard !Task.isCancelled else {
                    self.spatial3DImageState = .notGenerated
                    return
                }

                self.spatial3DImageState = .generated

                // Track that this image was converted
                await Spatial3DConversionTracker.shared.markAsConverted(url: self.imageURL)
                await Spatial3DConversionTracker.shared.setLastViewingMode(url: self.imageURL, mode: .spatial3D)

                if let aspectRatio = imagePresentationComponent.aspectRatio(for: .spatial3D) {
                    self.imageAspectRatio = CGFloat(aspectRatio)
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.photoWindow.error("Error generating spatial 3D image: \(error.localizedDescription, privacy: .public)")
                    self.spatial3DImageState = .notGenerated
                }
            }
        }
        generateTask = task

        // Wait for generation to complete
        await task.value
        generateTask = nil
    }

    /// Toggle 2D/3D view
    func toggleSpatial3DView() {
        guard var imagePresentationComponent = contentEntity.components[ImagePresentationComponent.self] else {
            return
        }

        // Toggle viewing mode
        if imagePresentationComponent.viewingMode == .spatial3D {
            imagePresentationComponent.desiredViewingMode = .mono
            contentEntity.components.set(imagePresentationComponent)
            Task {
                await Spatial3DConversionTracker.shared.setLastViewingMode(url: imageURL, mode: .mono)
            }
        } else if spatial3DImageState == .generated {
            imagePresentationComponent.desiredViewingMode = .spatial3D
            contentEntity.components.set(imagePresentationComponent)
            Task {
                await Spatial3DConversionTracker.shared.setLastViewingMode(url: imageURL, mode: .spatial3D)
            }
        }
    }

    /// Check if the current image was previously converted and auto-generate if so
    private func autoGenerateSpatial3DIfPreviouslyConverted() async {
        guard !isAnimatedGIF,
              spatial3DImageState == .notGenerated else {
            return
        }

        // Respect the user's last-used mode for this image
        if let lastMode = await Spatial3DConversionTracker.shared.lastViewingMode(url: imageURL), lastMode == .mono {
            AppLogger.photoWindow.debug("Skipping auto-generation; last mode was 2D")
            return
        }

        let wasConverted = await Spatial3DConversionTracker.shared.wasConverted(url: imageURL)
        if wasConverted {
            AppLogger.photoWindow.debug("Auto-generating spatial 3D for previously converted image")
            await generateSpatial3DImage()
        }
    }

    // MARK: - UI Auto-Hide

    func startAutoHideTimer() {
        cancelAutoHideTimer()

        guard appModel.autoHideDelay > 0 else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled {
                isUIHidden = true
            }
        }
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    func toggleUIVisibility() {
        isUIHidden.toggle()
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Slideshow

    /// Start a random slideshow in this window
    func startSlideshow() async {
        guard !isSlideshowActive else { return }

        isSlideshowActive = true
        slideshowHistory = [image]  // Start with current image in history
        slideshowImages = []
        slideshowIndex = 0

        // Fetch initial batch of random images (no seed for true randomness)
        await fetchRandomSlideshowImages()

        // Start the slideshow timer
        startSlideshowTimer()
    }

    /// Fetch a batch of random images for the slideshow
    private func fetchRandomSlideshowImages() async {
        // Create a filter with random sort and no seed (unseeded = different order each time)
        var randomFilter = ImageFilterCriteria()
        randomFilter.sortField = .random
        randomFilter.randomSeed = nil  // Unseeded for true random

        do {
            let result = try await appModel.imageSource.fetchImages(page: 0, pageSize: 10, filter: randomFilter)
            slideshowImages = result.images
            AppLogger.photoWindow.debug("Fetched \(result.images.count, privacy: .public) random images for slideshow")
        } catch {
            AppLogger.photoWindow.error("Failed to fetch slideshow images: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start the slideshow timer
    private func startSlideshowTimer() {
        slideshowTask?.cancel()
        slideshowTask = Task { @MainActor in
            while isSlideshowActive && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(appModel.slideshowDelay))
                if !Task.isCancelled && isSlideshowActive {
                    await advanceSlideshow()
                }
            }
        }
    }

    /// Advance to the next slideshow image
    private func advanceSlideshow() async {
        slideshowIndex += 1

        // If we've gone through all fetched images, fetch more
        if slideshowIndex >= slideshowImages.count {
            await fetchRandomSlideshowImages()
            slideshowIndex = 0
        }

        if slideshowIndex < slideshowImages.count {
            let nextImage = slideshowImages[slideshowIndex]
            await switchToImage(nextImage)
            slideshowHistory.append(nextImage)
        }
    }

    /// Switch to displaying a different image
    private func switchToImage(_ newImage: GalleryImage) async {
        image = newImage
        imageURL = newImage.fullSizeURL
        isLoadingDetailImage = true

        // Wait for any in-progress generation to finish before removing the
        // component. RealityKit crashes if we remove ImagePresentationComponent
        // while generate() is still running internally.
        if let task = generateTask {
            task.cancel()
            await task.value
            generateTask = nil
        }

        // Release all previous image resources
        spatial3DImageState = .notGenerated
        spatial3DImage = nil
        isAnimatedGIF = false
        currentImageData = nil
        displayImage = nil
        nativeImageDimensions = nil
        currentDisplayMaxDimension = 0
        isLoadingDisplayImage = false
        contentEntity.components.remove(ImagePresentationComponent.self)

        // Always start in 2D mode when switching images
        is3DMode = false

        // Load image data to detect if it's a GIF
        await loadImageDataForDetail(url: newImage.fullSizeURL)

        // Load 2D display image if not a GIF
        if !isAnimatedGIF, let windowSize = lastWindowSize {
            await loadDisplayImage(for: windowSize)
        }
    }

    /// Go to the next slideshow image manually
    func nextSlideshowImage() async {
        guard isSlideshowActive else { return }

        // Reset the timer since user manually advanced
        startSlideshowTimer()

        await advanceSlideshow()
    }

    /// Go to the previous slideshow image
    func previousSlideshowImage() async {
        guard isSlideshowActive, slideshowHistory.count > 1 else { return }

        // Reset the timer since user manually navigated
        startSlideshowTimer()

        // Remove current image from history
        slideshowHistory.removeLast()

        // Go back to the previous image
        if let previousImage = slideshowHistory.last {
            await switchToImage(previousImage)
        }
    }

    /// Stop the slideshow
    func stopSlideshow() {
        isSlideshowActive = false
        slideshowTask?.cancel()
        slideshowTask = nil
        slideshowImages = []
        slideshowHistory = []
        slideshowIndex = 0
    }

    /// Check if there's a previous slideshow image available
    var hasPreviousSlideshowImage: Bool {
        slideshowHistory.count > 1
    }

    // MARK: - Resource Cleanup

    /// Explicitly release large resources when the window is being dismissed.
    /// Ensures GPU textures and image data are freed promptly rather than
    /// waiting for ARC/deinit which may be delayed by SwiftUI state retention.
    func cleanup() {
        if isSlideshowActive {
            stopSlideshow()
        }

        // Cancel all tasks
        autoHideTask?.cancel()
        autoHideTask = nil
        slideshowTask?.cancel()
        slideshowTask = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil

        // If 3D generation is in progress, we CANNOT remove the
        // ImagePresentationComponent — RealityKit's generate() ignores Swift
        // cooperative cancellation and will crash if the component is gone when
        // its progress callback fires. Instead, cancel the task and let the
        // entity + component be deallocated naturally when the model is released.
        let generationActive = generateTask != nil
        generateTask?.cancel()
        generateTask = nil

        // Release Spatial3DImage GPU texture
        spatial3DImage = nil
        spatial3DImageState = .notGenerated

        // Release image data
        currentImageData = nil
        displayImage = nil

        // Only remove the component if generation is NOT active.
        // If active, the entity retains the component until ARC releases both.
        if !generationActive {
            contentEntity.components.remove(ImagePresentationComponent.self)
        }

        // Clear collection references
        galleryImages = []
        slideshowImages = []
        slideshowHistory = []

        appModel.openPhotoWindowCount -= 1
    }

    // MARK: - Gallery Navigation

    /// Navigate to next image in gallery
    func nextGalleryImage() async {
        guard hasNextGalleryImage else { return }
        currentGalleryIndex += 1

        // Trigger prefetch if approaching end
        checkAndLoadMoreIfNeeded()

        let nextImage = galleryImages[currentGalleryIndex]
        await switchToImage(nextImage)
    }

    /// Navigate to previous image in gallery
    func previousGalleryImage() async {
        guard hasPreviousGalleryImage else { return }
        currentGalleryIndex -= 1
        let prevImage = galleryImages[currentGalleryIndex]
        await switchToImage(prevImage)
    }

    /// Check if there's a next image in gallery
    var hasNextGalleryImage: Bool {
        currentGalleryIndex + 1 < galleryImages.count
    }

    /// Check if there's a previous image in gallery
    var hasPreviousGalleryImage: Bool {
        currentGalleryIndex > 0
    }

    /// Current position in gallery (1-indexed for display)
    var currentGalleryPosition: Int {
        currentGalleryIndex + 1
    }

    /// Total images in gallery
    var galleryImageCount: Int {
        galleryImages.count
    }

    // MARK: - Viewer Lazy Loading

    /// Load more images using the snapshotted filter
    private func loadMoreImages() async {
        guard !isLoadingMoreImages && hasMorePages else { return }

        isLoadingMoreImages = true
        defer { isLoadingMoreImages = false }

        do {
            let result = try await imageSource.fetchImages(page: currentPage, pageSize: pageSize, filter: snapshotFilter)
            galleryImages.append(contentsOf: result.images)
            hasMorePages = result.hasMore
            currentPage += 1
            AppLogger.photoWindow.debug("Loaded \(result.images.count, privacy: .public) more images for window, total: \(self.galleryImages.count, privacy: .public)")
        } catch {
            AppLogger.photoWindow.error("Failed to load more images for window: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Check if more images should be loaded based on current position
    private func checkAndLoadMoreIfNeeded() {
        let remaining = galleryImages.count - currentGalleryIndex - 1
        if remaining <= prefetchThreshold && hasMorePages && !isLoadingMoreImages {
            Task {
                await loadMoreImages()
            }
        }
    }

    // MARK: - Rating & O Counter

    func updateImageRating(stashId: String, rating100: Int?) async throws {
        try await appModel.updateImageRating(stashId: stashId, rating100: rating100)
        // Update local state
        image.rating100 = rating100
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].rating100 = rating100
        }
    }

    func incrementImageOCounter(stashId: String) async throws {
        try await appModel.incrementImageOCounter(stashId: stashId)
        // Sync from appModel's updated value
        if let updated = appModel.galleryImages.first(where: { $0.stashId == stashId }) {
            image.oCounter = updated.oCounter
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = image.oCounter
        }
    }

    func decrementImageOCounter(stashId: String) async throws {
        try await appModel.decrementImageOCounter(stashId: stashId)
        if let updated = appModel.galleryImages.first(where: { $0.stashId == stashId }) {
            image.oCounter = updated.oCounter
        }
        if let index = galleryImages.firstIndex(where: { $0.stashId == stashId }) {
            galleryImages[index].oCounter = image.oCounter
        }
    }
}
