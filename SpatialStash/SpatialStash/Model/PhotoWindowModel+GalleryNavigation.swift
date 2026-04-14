/*
 Spatial Stash - Photo Window Model: Gallery Navigation

 Extension for gallery image navigation, lazy loading pagination, and rating/counter updates.
 */

import os
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Gallery Navigation

    /// Switch to displaying a different image, releasing previous resources and loading new ones.
    func switchToImage(_ newImage: GalleryImage) async {
        let oldImageURL = imageURL
        image = newImage
        imageURL = newImage.fullSizeURL
        isLoadingDetailImage = true

        // Update pop-out window tracking so saved window groups capture the current image
        if let windowValue = popOutWindowValue {
            appModel.updatePopOutWindowImage(windowValueId: windowValue.id, oldImageURL: oldImageURL, newImage: newImage)
        }

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
        isAnimatedWebP = false
        isAnimatedWebVisual = false
        currentImageData = nil
        animatedImageSourceURL = nil
        gifHEVCURL = nil
        displayTexture = nil
        displayImage = nil
        nativeImageDimensions = nil
        currentDisplayMaxDimension = 0
        isLoadingDisplayImage = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        clearAutoEnhanceState()
        clearBackgroundRemovalState()

        is3DMode = false
        desiredViewingMode = .mono
        isImageFlipped = false
        resolutionOverride = nil
        currentAdjustments = VisualAdjustments()
        isShowingAdjustmentPreview = false
        adjustments3DReloadTask?.cancel()

        if appModel.rememberImageEnhancements {
            let savedOverride = await ImageEnhancementTracker.shared.resolutionOverride(url: newImage.fullSizeURL)
            if savedOverride != nil {
                resolutionOverride = savedOverride
            }
            let savedSize = await ImageEnhancementTracker.shared.windowSize(url: newImage.fullSizeURL)
            savedWindowSize = savedSize
            if let savedSize {
                lastWindowSize = savedSize
            }
        } else {
            savedWindowSize = nil
        }

        await loadImageDataForDetail(url: newImage.fullSizeURL)

        if !isAnimatedImage && !useRealityKitDisplay, let windowSize = lastWindowSize {
            await loadDisplayImage(for: windowSize)
        }

        if appModel.rememberImageEnhancements, !is3DMode {
            let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: newImage.fullSizeURL)
            if wasFlipped {
                isImageFlipped = true
            }
        }

        await restoreAdjustments()
        await applyPendingViewingMode()
    }

    /// Navigate to next image in gallery
    func nextGalleryImage() async {
        recordInteraction()
        guard hasNextGalleryImage else { return }
        currentGalleryIndex += 1

        // Trigger prefetch if approaching end
        checkAndLoadMoreIfNeeded()

        let nextImage = galleryImages[currentGalleryIndex]
        await switchToImage(nextImage)
    }

    /// Navigate to previous image in gallery
    func previousGalleryImage() async {
        recordInteraction()
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
    func loadMoreImages() async {
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
    func checkAndLoadMoreIfNeeded() {
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
