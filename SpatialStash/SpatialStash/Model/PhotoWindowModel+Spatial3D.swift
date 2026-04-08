/*
 Spatial Stash - Photo Window Model: Spatial 3D

 Extension for 3D mode activation/deactivation, ImagePresentationComponent creation,
 spatial 3D generation, viewing mode switching, and resolution override.
 */

import Foundation
import ImageIO
import os
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - 3D Mode Activation

    /// Activate RealityKit 3D mode. Loads the full-resolution ImagePresentationComponent
    /// from the disk cache and releases the lightweight 2D display image.
    /// - Parameter generateImmediately: If true, RealityView will generate the 3D depth map
    ///   right after creating the component (used when the user explicitly taps "Generate 3D").
    func activate3DMode(generateImmediately: Bool = false) {
        recordInteraction()
        guard !isAnimatedGIF, !is3DMode else { return }
        clearBackgroundRemovalState()
        if isImageFlipped {
            isImageFlipped = false
            Task { await trackFlipState() }
        }
        is3DMode = true
        isLoadingDetailImage = true
        pendingGenerate3D = generateImmediately
        // RealityView's init closure will call createImagePresentationComponent()
    }

    /// Deactivate 3D mode and return to 2D display.
    /// When useRealityKitDisplay is set, toggles the RealityKit viewing mode back
    /// to mono instead of switching to the lightweight SwiftUI Image display.
    func deactivate3DMode() async {
        recordInteraction()
        guard is3DMode else { return }

        if useRealityKitDisplay {
            // Stay in RealityKit but directly switch viewing mode to mono
            guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
            guard ipc.viewingMode != .mono else { return }
            ipc.desiredViewingMode = .mono
            desiredViewingMode = .mono
            contentEntity.components.set(ipc)
            if let ar = ipc.aspectRatio(for: .mono) { imageAspectRatio = CGFloat(ar) }
            immersiveResizeTrigger += 1
            await trackViewingMode(.mono)
            return
        }

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
        desiredViewingMode = .mono  // Reset to mono when exiting 3D entirely
        isShowingAdjustmentPreview = false
        adjustments3DReloadTask?.cancel()

        // Record that the user explicitly exited 3D so auto-restore doesn't re-enable it
        await trackViewingMode(.mono)

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
        // If a component was already pre-created (e.g. with baked-in adjustments
        // by reloadImagePresentationWithAdjustments), keep it and skip recreation.
        if contentEntity.components[ImagePresentationComponent.self] != nil {
            inputPlaneEntity = Entity()
            if desiredViewingMode != .spatial3DImmersive {
                desiredViewingMode = .mono
            }
            displayTexture = nil
            displayImage = nil
            isLoadingDetailImage = false
            return
        }

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

            // Respect the max image resolution setting by downsampling the source
            // image before passing it to RealityKit's Spatial3DImage
            let effectiveRes = effectiveMaxResolution
            if effectiveRes > 0,
               let downsampledData = Self.createDownsampledImageData(from: sourceURL, maxDimension: CGFloat(effectiveRes)),
               let downsampledSource = CGImageSourceCreateWithData(downsampledData as CFData, nil) {
                AppLogger.photoWindow.debug("3D conversion using downsampled source (max \(effectiveRes, privacy: .public)px)")
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(imageSource: downsampledSource)
            } else {
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(contentsOf: sourceURL)
            }
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
        // Initialize to mono unless already targeting immersive (e.g. auto-restore)
        if desiredViewingMode != .spatial3DImmersive {
            desiredViewingMode = .mono
        }
        if let aspectRatio = imagePresentationComponent.aspectRatio(for: .mono) {
            imageAspectRatio = CGFloat(aspectRatio)
        }

        // Release CPU-side resources since RealityKit owns the GPU texture now.
        // The raw data can be reloaded from disk cache if needed (e.g. switching
        // back to 2D mode), but keeping it in RAM wastes dirty memory while the
        // GPU texture is resident.
        displayTexture = nil
        displayImage = nil
        currentImageData = nil

        isLoadingDetailImage = false
        // Note: Auto-generation is handled by PhotoWindowView after entity is added to scene
    }

    /// Creates downsampled JPEG data from an image URL for use with RealityKit's Spatial3DImage.
    /// Returns nil if the image is already within the max dimension or downsampling fails,
    /// allowing the caller to fall back to the full-resolution URL-based initializer.
    static func createDownsampledImageData(from url: URL, maxDimension: CGFloat) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        // Check native dimensions — skip downsampling if already within limit
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           max(width, height) <= maxDimension {
            return nil
        }

        // Downsample using CGImageSource thumbnail API (memory-efficient, no full decode)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
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
        recordInteraction()
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
        // generation animation. Preserve .spatial3DImmersive if already set (e.g. when
        // the user clicked immersive or auto-restore targets immersive).
        imagePresentationComponent.desiredViewingMode = .spatial3D
        if desiredViewingMode != .spatial3DImmersive {
            desiredViewingMode = .spatial3D
        }
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

                // Determine if immersive mode is desired — either because the user
                // explicitly pressed the immersive button (desiredViewingMode) or
                // because auto-restore found a saved immersive preference in the tracker.
                var shouldBeImmersive = self.desiredViewingMode == .spatial3DImmersive
                if !shouldBeImmersive && self.appModel.rememberImageEnhancements {
                    let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: self.imageURL)
                    shouldBeImmersive = lastMode == .spatial3DImmersive
                }

                // Track that this image was converted
                await self.trackImageConverted()

                // Apply the final viewing mode (immersive or spatial3D)
                if shouldBeImmersive {
                    self.applyDesiredViewingMode(.spatial3DImmersive)
                    await self.trackViewingMode(.spatial3DImmersive)
                } else {
                    if let aspectRatio = imagePresentationComponent.aspectRatio(for: .spatial3D) {
                        self.imageAspectRatio = CGFloat(aspectRatio)
                    }
                    await self.trackViewingMode(.spatial3D)
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

    /// Whether the RealityKit component is currently showing spatial 3D (vs mono)
    var isViewingSpatial3D: Bool {
        if let viewingMode = contentEntity.components[ImagePresentationComponent.self]?.viewingMode {
            return viewingMode == .spatial3D || viewingMode == .spatial3DImmersive
        }
        return false
    }

    /// Whether the RealityKit component is currently showing immersive spatial 3D
    var isViewingSpatial3DImmersive: Bool {
        contentEntity.components[ImagePresentationComponent.self]?.viewingMode == .spatial3DImmersive
    }

    /// Current viewing mode of the ImagePresentationComponent
    var currentViewingMode: ImagePresentationComponent.ViewingMode? {
        contentEntity.components[ImagePresentationComponent.self]?.viewingMode
    }

    // MARK: - Resolution Override

    /// Apply a per-window resolution override and reload the display image.
    /// Pass nil to clear the override and revert to the global setting.
    func applyResolutionOverride(_ resolution: Int?) async {
        recordInteraction()
        resolutionOverride = resolution
        await trackResolutionOverride()
        guard !isAnimatedGIF, !is3DMode else { return }

        if backgroundRemovalState == .removed {
            // Re-downscale the background-removed image at the new resolution
            await reloadBackgroundRemovedAtCurrentResolution()
            return
        }

        if currentAdjustments.isAutoEnhanced {
            // Re-downscale the auto-enhanced image at the new resolution
            await reloadAutoEnhancedAtCurrentResolution()
            return
        }

        guard backgroundRemovalState == .original else { return }

        // Reset current dimension to force reload
        currentDisplayMaxDimension = 0
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        await loadDisplayImage(for: windowSize)
    }

    // MARK: - Viewing Mode Switching

    /// Switch directly to a specific viewing mode without cycling.
    /// If the image is still loading, the mode is queued and applied once loading finishes.
    func switchToViewingMode(_ mode: ImagePresentationComponent.ViewingMode) async {
        if isLoadingDetailImage {
            pendingViewingMode = mode
            desiredViewingMode = mode
            return
        }
        pendingViewingMode = nil
        if mode == .mono {
            await deactivate3DMode()
        } else if mode == .spatial3D {
            if spatial3DImageState == .notGenerated {
                await generateSpatial3DImage()
                // generateSpatial3DImage already sets desiredViewingMode = .spatial3D
            } else {
                guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                guard ipc.viewingMode != .spatial3D else { return }
                let wasImmersive = ipc.viewingMode == .spatial3DImmersive
                ipc.desiredViewingMode = .spatial3D
                desiredViewingMode = .spatial3D
                contentEntity.components.set(ipc)
                if let ar = ipc.aspectRatio(for: .spatial3D) { imageAspectRatio = CGFloat(ar) }
                if wasImmersive { immersiveResizeTrigger += 1 }
                Task { await self.trackViewingMode(.spatial3D) }
            }
        } else if mode == .spatial3DImmersive {
            if spatial3DImageState == .notGenerated {
                desiredViewingMode = .spatial3DImmersive
                await generateSpatial3DImage()
                applyDesiredViewingMode(.spatial3DImmersive)
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            } else {
                guard let ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                guard ipc.viewingMode != .spatial3DImmersive else { return }
                applyDesiredViewingMode(.spatial3DImmersive)
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            }
        }
    }

    /// Apply a viewing mode that was queued while the image was loading.
    func applyPendingViewingMode() async {
        guard let mode = pendingViewingMode else { return }
        pendingViewingMode = nil
        guard !isAnimatedGIF else { return }
        await switchToViewingMode(mode)
    }

    /// Check if the current image was previously converted and auto-generate if so
    func autoGenerateSpatial3DIfPreviouslyConverted() async {
        guard appModel.rememberImageEnhancements else { return }
        guard !isAnimatedGIF,
              spatial3DImageState == .notGenerated else {
            return
        }

        // Respect the user's last-used mode for this image
        if let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL), lastMode == .mono {
            AppLogger.photoWindow.debug("Skipping auto-generation; last mode was 2D")
            return
        }

        let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
        if wasConverted {
            // Set desired mode before generation so the correct button shows the spinner
            let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
            if lastMode == .spatial3DImmersive {
                desiredViewingMode = .spatial3DImmersive
            }
            AppLogger.photoWindow.debug("Auto-generating spatial 3D for previously converted image")
            await generateSpatial3DImage()
        }
    }

    // MARK: - Viewing Mode Helper (Deduplicated)

    /// Apply a desired viewing mode to the ImagePresentationComponent, updating
    /// aspect ratio and immersive resize trigger as needed.
    func applyDesiredViewingMode(_ mode: ImagePresentationComponent.ViewingMode) {
        guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
        ipc.desiredViewingMode = mode
        desiredViewingMode = mode
        contentEntity.components.set(ipc)
        if let ar = ipc.aspectRatio(for: mode) { imageAspectRatio = CGFloat(ar) }
        if mode == .spatial3DImmersive { immersiveResizeTrigger += 1 }
    }
}
