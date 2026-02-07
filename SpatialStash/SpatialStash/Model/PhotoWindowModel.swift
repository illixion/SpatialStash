/*
 Spatial Stash - Photo Window Model

 Per-window model for individual photo display windows.
 Each photo window gets its own instance with independent state.
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

    // MARK: - Image Preloading

    /// Preloaded image data cache (keyed by image ID)
    private var preloadedImages: [UUID: PreloadedImageData] = [:]

    /// Currently preloading task
    private var preloadTask: Task<Void, Never>?

    /// Data structure for preloaded images
    private struct PreloadedImageData {
        let imageData: Data?
        let isAnimatedGIF: Bool
        let aspectRatio: CGFloat?
        let spatial3DImage: ImagePresentationComponent.Spatial3DImage?
    }

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

        // Load image data to detect if it's a GIF
        Task {
            await loadImageDataForDetail(url: image.fullSizeURL)
        }
    }
    
    // MARK: - Image Loading
    
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
            AppLogger.photoWindow.error("Error loading image data: \(error.localizedDescription, privacy: .public)")
            isLoadingDetailImage = false
        }
    }
    
    // MARK: - Image Presentation Component
    
    /// Create the ImagePresentationComponent for the current image
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
        
        do {
            // Generate the Spatial3DImage scene.
            try await spatial3DImage.generate()
            spatial3DImageState = .generated
            
            // Track that this image was converted
            await Spatial3DConversionTracker.shared.markAsConverted(url: imageURL)
            await Spatial3DConversionTracker.shared.setLastViewingMode(url: imageURL, mode: .spatial3D)
            
            if let aspectRatio = imagePresentationComponent.aspectRatio(for: .spatial3D) {
                imageAspectRatio = CGFloat(aspectRatio)
            }
        } catch {
            AppLogger.photoWindow.error("Error generating spatial 3D image: \(error.localizedDescription, privacy: .public)")
            spatial3DImageState = .notGenerated
        }
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

        // Preload first images for seamless start
        if !slideshowImages.isEmpty {
            preloadNextImages(from: slideshowImages, startIndex: 0)
        }

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
            // Preload first image of new batch
            if !slideshowImages.isEmpty {
                preloadNextImages(from: slideshowImages, startIndex: 0)
            }
        }

        if slideshowIndex < slideshowImages.count {
            let nextImage = slideshowImages[slideshowIndex]
            await switchToImage(nextImage)
            slideshowHistory.append(nextImage)

            // Preload next slideshow image
            let nextIndex = slideshowIndex + 1
            if nextIndex < slideshowImages.count {
                preloadNextImages(from: slideshowImages, startIndex: nextIndex)
            }
        }
    }

    /// Switch to displaying a different image
    private func switchToImage(_ newImage: GalleryImage) async {
        // Check if we have preloaded data for this image
        if let preloaded = preloadedImages[newImage.id] {
            // Use preloaded data for instant switch
            image = newImage
            imageURL = newImage.fullSizeURL
            spatial3DImageState = .notGenerated
            currentImageData = preloaded.imageData
            isAnimatedGIF = preloaded.isAnimatedGIF

            if let aspectRatio = preloaded.aspectRatio {
                imageAspectRatio = aspectRatio
            }

            if isAnimatedGIF {
                // GIF is ready to display
                contentEntity.components.remove(ImagePresentationComponent.self)
                spatial3DImage = nil
                isLoadingDetailImage = false
            } else if let spatial3D = preloaded.spatial3DImage {
                // Static image with preloaded presentation component
                contentEntity.components.remove(ImagePresentationComponent.self)
                spatial3DImage = spatial3D
                let imagePresentationComponent = ImagePresentationComponent(spatial3DImage: spatial3D)
                contentEntity.components.set(imagePresentationComponent)
                if let aspectRatio = imagePresentationComponent.aspectRatio(for: .mono) {
                    imageAspectRatio = CGFloat(aspectRatio)
                }
                isLoadingDetailImage = false
                // Restore cached 2D/3D state for the new image (skip during slideshow)
                if !isSlideshowActive {
                    await autoGenerateSpatial3DIfPreviouslyConverted()
                }
            } else {
                // Preloaded data but no presentation component, create it
                isLoadingDetailImage = true
                contentEntity.components.remove(ImagePresentationComponent.self)
                spatial3DImage = nil
                await createImagePresentationComponent()
                // Restore cached 2D/3D state for the new image (skip during slideshow)
                if !isSlideshowActive {
                    await autoGenerateSpatial3DIfPreviouslyConverted()
                }
            }

            // Remove used preloaded data
            preloadedImages.removeValue(forKey: newImage.id)
        } else {
            // No preloaded data, load normally
            image = newImage
            imageURL = newImage.fullSizeURL
            isLoadingDetailImage = true
            spatial3DImageState = .notGenerated
            spatial3DImage = nil
            isAnimatedGIF = false
            currentImageData = nil
            contentEntity.components.remove(ImagePresentationComponent.self)

            // Load image data to detect if it's a GIF
            await loadImageDataForDetail(url: newImage.fullSizeURL)

            // Create the presentation component if not a GIF
            if !isAnimatedGIF {
                await createImagePresentationComponent()
                // Restore cached 2D/3D state for the new image (skip during slideshow)
                if !isSlideshowActive {
                    await autoGenerateSpatial3DIfPreviouslyConverted()
                }
            }
        }
    }

    // MARK: - Image Preloading

    /// Preload images for seamless transitions
    private func preloadNextImages(from images: [GalleryImage], startIndex: Int) {
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            // Preload next 1-2 images
            for i in startIndex..<min(startIndex + 2, images.count) {
                guard !Task.isCancelled else { break }
                let imageToPreload = images[i]

                // Skip if already preloaded
                guard preloadedImages[imageToPreload.id] == nil else { continue }

                await preloadImage(imageToPreload)
            }
        }
    }

    /// Preload a single image
    private func preloadImage(_ galleryImage: GalleryImage) async {
        let url = galleryImage.fullSizeURL

        do {
            // Load image data
            guard let data = try await ImageLoader.shared.loadImageData(from: url) else { return }

            let isGIF = data.isAnimatedGIF
            var aspectRatio: CGFloat?
            var spatial3D: ImagePresentationComponent.Spatial3DImage?

            if isGIF {
                // For GIFs, just get aspect ratio
                if let uiImage = UIImage(data: data) {
                    aspectRatio = uiImage.size.width / uiImage.size.height
                }
            } else {
                // For static images, create the spatial 3D image
                let sourceURL: URL
                if !url.isFileURL, let cached = await DiskImageCache.shared.cachedFileURL(for: url) {
                    sourceURL = cached
                } else {
                    sourceURL = url
                }

                spatial3D = try await ImagePresentationComponent.Spatial3DImage(contentsOf: sourceURL)
            }

            // Store preloaded data
            preloadedImages[galleryImage.id] = PreloadedImageData(
                imageData: data,
                isAnimatedGIF: isGIF,
                aspectRatio: aspectRatio,
                spatial3DImage: spatial3D
            )

            AppLogger.photoWindow.debug("Preloaded image: \(galleryImage.id, privacy: .public)")
        } catch {
            AppLogger.photoWindow.debug("Failed to preload image: \(error.localizedDescription, privacy: .public)")
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
        preloadTask?.cancel()
        preloadTask = nil
        slideshowImages = []
        slideshowHistory = []
        slideshowIndex = 0
        preloadedImages.removeAll()
    }

    /// Check if there's a previous slideshow image available
    var hasPreviousSlideshowImage: Bool {
        slideshowHistory.count > 1
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

        // Preload upcoming gallery images
        preloadNextImages(from: galleryImages, startIndex: currentGalleryIndex + 1)
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
}
