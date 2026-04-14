/*
 Spatial Stash - Photo Window Model: Visual Adjustments

 Extension for auto-enhance, brightness/contrast/saturation adjustments,
 and 3D adjustment preview system.
 */

import CoreImage
import ImageIO
import Metal
import os
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    // MARK: - Visual Adjustment Methods

    /// Apply visual adjustments and persist to tracker.
    func applyAdjustments(_ adjustments: VisualAdjustments) {
        recordInteraction()
        currentAdjustments = adjustments
        Task { await trackAdjustments() }
    }

    /// Reset current per-image adjustments to defaults.
    func resetCurrentAdjustments() {
        recordInteraction()
        currentAdjustments = VisualAdjustments()
        if backgroundRemovalState == .removed {
            // Swap to regular bg-removed texture (auto-enhance is now off)
            if let regular = backgroundRemovedTexture {
                displayTexture = regular
                imageAspectRatio = CGFloat(regular.width) / CGFloat(regular.height)
            }
        } else if autoEnhancedDisplayTexture != nil {
            // Restore the non-enhanced display image
            autoEnhancedDisplayTexture = nil
            currentDisplayMaxDimension = 0
            if !is3DMode, !isAnimatedImage, let windowSize = lastWindowSize {
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
        Task { await trackAdjustments() }
    }

    /// Toggle auto-enhance: applies CIImage auto-adjustment filters to generate
    /// an enhanced base image. Manual sliders (brightness/contrast/saturation) are
    /// applied as SwiftUI view modifiers on top of this base.
    /// When background removal is active, swaps between regular and auto-enhanced
    /// bg-removed variants instead of running the standard auto-enhance pipeline.
    func toggleAutoEnhance() async {
        recordInteraction()
        guard !isProcessingAutoEnhance else { return }

        // Special handling when background removal is active: swap between bg-removed variants
        if backgroundRemovalState == .removed {
            if currentAdjustments.isAutoEnhanced {
                // Turn off: swap to regular bg-removed texture
                if let regular = backgroundRemovedTexture {
                    displayTexture = regular
                    imageAspectRatio = CGFloat(regular.width) / CGFloat(regular.height)
                }
                currentAdjustments.isAutoEnhanced = false
                await trackAutoEnhanceState()
            } else {
                // Turn on: swap to auto-enhanced bg-removed texture
                if let enhanced = autoEnhancedBackgroundRemovedTexture {
                    // In-memory cache hit
                    displayTexture = enhanced
                    imageAspectRatio = CGFloat(enhanced.width) / CGFloat(enhanced.height)
                    currentAdjustments.isAutoEnhanced = true
                    await trackAutoEnhanceState()
                } else if let enhancedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL, isAutoEnhanced: true) {
                    // Disk cache hit — load and upload to GPU
                    isProcessingAutoEnhance = true
                    let targetDimension = backgroundRemovalTargetDimension()
                    let useLossy = appModel.useLossyTextureCompression
                    let sendable = await Task.detached { [enhancedURL, targetDimension, useLossy] () -> SendableTexture? in
                        guard let tex = MetalImageRenderer.shared?.createTexture(from: enhancedURL, maxDimension: targetDimension, useLossyCompression: useLossy) else { return nil }
                        return SendableTexture(texture: tex)
                    }.value
                    if let texture = sendable?.texture {
                        autoEnhancedBackgroundRemovedTexture = texture
                        displayTexture = texture
                        imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
                        currentAdjustments.isAutoEnhanced = true
                        await trackAutoEnhanceState()
                    }
                    isProcessingAutoEnhance = false
                } else {
                    // No cached enhanced variant (e.g. bg removal ran before this feature).
                    // Generate on-demand from the regular bg-removed cache.
                    await generateEnhancedBgRemovedVariant()
                }
            }

            // In 3D mode, reload the component with adjusted pixels
            reloadImagePresentationWithAdjustments()
            return
        }

        if currentAdjustments.isAutoEnhanced {
            // Turn off: restore original display image
            restoreFromAutoEnhance()
        } else {
            // Turn on: 3-tier cache lookup (in-memory → disk → on-demand)
            if let cached = autoEnhancedDisplayTexture {
                // Tier 1: in-memory (instant toggle-back)
                preAutoEnhanceDisplayTexture = displayTexture
                displayTexture = cached
                imageAspectRatio = CGFloat(cached.width) / CGFloat(cached.height)
                currentAdjustments.isAutoEnhanced = true
                await trackAutoEnhanceState()
            } else if let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
                      let cachedImage = UIImage(data: cachedData) {
                // Tier 2: persistent disk cache
                await applyDownscaledAutoEnhance(cachedImage)
            } else {
                // Tier 3: process from raw data and cache
                await performFullResolutionAutoEnhance()
            }
        }

        // In 3D mode, reload the component with adjusted pixels
        reloadImagePresentationWithAdjustments()
    }

    /// Apply auto-enhance from a full-resolution cached image (downscale for display).
    func applyDownscaledAutoEnhance(_ fullResImage: UIImage) async {
        isProcessingAutoEnhance = true

        let texture = await downscaleAndUploadTexture(fullResImage)

        autoEnhancedDisplayTexture = texture
        preAutoEnhanceDisplayTexture = displayTexture
        if !is3DMode, !isAnimatedImage, let texture {
            displayTexture = texture
            let w = CGFloat(texture.width)
            let h = CGFloat(texture.height)
            imageAspectRatio = w / h
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false
        isLoadingDetailImage = false

        await trackAutoEnhanceState()
    }

    /// Generate the auto-enhanced bg-removed variant on-demand when it doesn't
    /// exist in cache (e.g. bg removal ran before this feature was added).
    func generateEnhancedBgRemovedVariant() async {
        // Load regular bg-removed image from disk cache
        guard let regularData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
              let regularImage = UIImage(data: regularData),
              let cgImage = regularImage.cgImage else {
            AppLogger.photoWindow.warning("Cannot generate enhanced bg-removed variant: no cached regular image")
            return
        }

        isProcessingAutoEnhance = true

        let enhanced = await Task.detached { () -> UIImage? in
            let ciImage = CIImage(cgImage: cgImage)
            let result = Self.applyAutoAdjustmentFilters(to: ciImage)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let outputCG = context.createCGImage(result, from: result.extent) else { return nil }
            return UIImage(cgImage: outputCG, scale: regularImage.scale, orientation: regularImage.imageOrientation)
        }.value

        guard let enhanced else {
            isProcessingAutoEnhance = false
            return
        }

        // Cache the enhanced variant to disk
        await BackgroundRemovalCache.shared.saveImage(enhanced, for: imageURL, isAutoEnhanced: true)

        // Downscale and upload to GPU texture
        let texture = await downscaleAndUploadTexture(enhanced)
        autoEnhancedBackgroundRemovedTexture = texture

        if let texture {
            displayTexture = texture
            imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false

        await trackAutoEnhanceState()
    }

    /// Process auto-enhancement from raw image data, cache result, and apply.
    func performFullResolutionAutoEnhance() async {
        guard let imageData = currentImageData,
              let ciImage = CIImage(data: imageData) else {
            return
        }

        isProcessingAutoEnhance = true

        let enhanced = await Task.detached { () -> UIImage? in
            let result = Self.applyAutoAdjustmentFilters(to: ciImage)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let cgImage = context.createCGImage(result, from: result.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value

        guard let enhanced else {
            isProcessingAutoEnhance = false
            isLoadingDetailImage = false
            return
        }

        // Cache full-resolution result to disk
        await AutoEnhanceCache.shared.saveImage(enhanced, for: imageURL)

        // Downscale and upload to GPU texture
        let texture = await downscaleAndUploadTexture(enhanced)

        autoEnhancedDisplayTexture = texture
        preAutoEnhanceDisplayTexture = displayTexture
        if !is3DMode, !isAnimatedImage, let texture {
            displayTexture = texture
            let w = CGFloat(texture.width)
            let h = CGFloat(texture.height)
            imageAspectRatio = w / h
        }
        currentAdjustments.isAutoEnhanced = true
        isProcessingAutoEnhance = false
        isLoadingDetailImage = false

        await trackAutoEnhanceState()
    }

    /// Restore the original (non-enhanced) display image.
    func restoreFromAutoEnhance() {
        currentAdjustments.isAutoEnhanced = false
        if let original = preAutoEnhanceDisplayTexture {
            displayTexture = original
            let w = CGFloat(original.width)
            let h = CGFloat(original.height)
            imageAspectRatio = w / h
        } else {
            // Edge case: no original stored (e.g. auto-restored on open)
            displayTexture = nil
            if let windowSize = lastWindowSize {
                isLoadingDetailImage = true
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
        Task { await trackAutoEnhanceState() }
    }

    /// Persist auto-enhance state via viewing mode and adjustments trackers.
    func trackAutoEnhanceState() async {
        if backgroundRemovalState == .removed {
            if currentAdjustments.isAutoEnhanced {
                await trackViewingMode(.backgroundRemovedAutoEnhanced)
            } else {
                await trackViewingMode(.backgroundRemoved)
            }
        } else {
            if currentAdjustments.isAutoEnhanced {
                await trackViewingMode(.autoEnhanced)
            } else {
                await trackViewingMode(.mono)
            }
        }
        await trackAdjustments()
    }

    /// Reload auto-enhanced image at the current effective resolution (for window resize).
    func reloadAutoEnhancedAtCurrentResolution() async {
        guard currentAdjustments.isAutoEnhanced else { return }

        guard let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
              let fullResImage = UIImage(data: cachedData) else {
            AppLogger.photoWindow.warning("Cannot reload auto-enhanced image: no cached data")
            return
        }

        let texture = await downscaleAndUploadTexture(fullResImage)
        autoEnhancedDisplayTexture = texture
        displayTexture = texture
        if let texture {
            imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
        }
    }

    func clearAutoEnhanceState() {
        autoEnhancedDisplayTexture = nil
        preAutoEnhanceDisplayTexture = nil
        isProcessingAutoEnhance = false
    }

    // MARK: - 3D Adjustment Preview

    /// Reload the ImagePresentationComponent with visual adjustments applied via CIFilter.
    /// Called when adjustments change while in 3D mode. Switches to the lightweight 2D
    /// SwiftUI Image branch with a thumbnail so SwiftUI modifiers provide instant feedback.
    /// The expensive 3D recalculation runs after sliders settle for 2 seconds.
    func reloadImagePresentationWithAdjustments() {
        guard is3DMode || isShowingAdjustmentPreview else { return }

        // Switch from 3D to 2D preview mode on first call.
        // This sets is3DMode = false so PhotoDisplayView renders the SwiftUI Image branch
        // (which already has .brightness/.contrast/.saturation modifiers) at the correct
        // window depth, avoiding z-fighting with ornaments.
        if !isShowingAdjustmentPreview {
            prePreviewSpatial3DState = spatial3DImageState
            isShowingAdjustmentPreview = true

            // Remove RealityKit resources
            contentEntity.components.remove(ImagePresentationComponent.self)
            spatial3DImage = nil
            spatial3DImageState = .notGenerated

            // Switch to 2D branch
            is3DMode = false

            // Load a thumbnail as displayImage for the 2D branch.
            // Try cached thumbnail first; fall back to generating from in-memory data.
            let url = imageURL
            let imageData = currentImageData
            Task { @MainActor [weak self] in
                guard let self, self.isShowingAdjustmentPreview else { return }
                if let thumbnail = await ThumbnailCache.shared.loadThumbnail(for: url) {
                    self.displayImage = thumbnail
                } else if let imageData {
                    let thumbnail = await Task.detached {
                        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil as UIImage? }
                        let options: [CFString: Any] = [
                            kCGImageSourceThumbnailMaxPixelSize: 400,
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true
                        ]
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil as UIImage? }
                        return UIImage(cgImage: cgImage)
                    }.value
                    if self.isShowingAdjustmentPreview {
                        self.displayImage = thumbnail
                    }
                }
            }
        }

        // Cancel any pending 3D reload and start a new debounce
        adjustments3DReloadTask?.cancel()
        adjustments3DReloadTask = Task { @MainActor [weak self] in
            // Wait for sliders to settle before expensive 3D recalculation.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isShowingAdjustmentPreview else { return }

            let adj = self.effectiveAdjustments
            let isIdentity = !adj.isModified || (!adj.isAutoEnhanced && adj.brightness == 0.0 && adj.contrast == 1.0 && adj.saturation == 1.0)

            if !isIdentity {
                // Pre-create the adjusted ImagePresentationComponent BEFORE switching
                // back to 3D mode, so the RealityView init finds it already set on the
                // entity and doesn't race with a second creation.
                guard let imageData = self.currentImageData,
                      let ciImage = CIImage(data: imageData) else {
                    AppLogger.visualAdjustments.warning("No image data available for 3D adjustment reload")
                    return
                }

                let adjustedData = await Task.detached { () -> Data? in
                    var result = ciImage

                    if adj.isAutoEnhanced {
                        result = Self.applyAutoAdjustmentFilters(to: result)
                    }

                    // CIColorControls contrast is much more aggressive than SwiftUI's
                    // .contrast() modifier. Empirically: SwiftUI 2.00 ≈ CIFilter 1.12,
                    // SwiftUI 1.61 ≈ CIFilter 1.07. Remap by scaling the deviation from 1.0.
                    let remappedContrast = 1.0 + (adj.contrast - 1.0) * 0.12

                    let colorControls = CIFilter(name: "CIColorControls")!
                    colorControls.setValue(result, forKey: kCIInputImageKey)
                    colorControls.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
                    colorControls.setValue(remappedContrast, forKey: kCIInputContrastKey)
                    colorControls.setValue(adj.saturation, forKey: kCIInputSaturationKey)
                    if let output = colorControls.outputImage { result = output }

                    let context = CIContext(options: [.useSoftwareRenderer: false])
                    guard let cgImage = context.createCGImage(result, from: result.extent) else { return nil }
                    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
                }.value

                guard !Task.isCancelled, let adjustedData,
                      let imageSource = CGImageSourceCreateWithData(adjustedData as CFData, nil) else {
                    AppLogger.visualAdjustments.warning("Failed to create adjusted image for 3D reload")
                    return
                }

                do {
                    self.spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(imageSource: imageSource)
                    guard let spatial3DImage = self.spatial3DImage else { return }
                    let ipc = ImagePresentationComponent(spatial3DImage: spatial3DImage)
                    self.contentEntity.components.set(ipc)
                    if let aspectRatio = ipc.aspectRatio(for: .mono) {
                        self.imageAspectRatio = CGFloat(aspectRatio)
                    }
                } catch {
                    AppLogger.visualAdjustments.error("Failed to reload ImagePresentationComponent: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }

            // Determine whether to re-generate 3D after restoring the component
            let shouldRegenerate3D = self.prePreviewSpatial3DState == .generated

            // Switch back to 3D mode — RealityView will be recreated.
            // For identity adjustments, the RealityView init calls createImagePresentationComponent().
            // For non-identity, the component is already set on contentEntity above.
            self.displayTexture = nil
            self.displayImage = nil
            self.isShowingAdjustmentPreview = false
            self.is3DMode = true
            self.pendingGenerate3D = shouldRegenerate3D
        }
    }

    // MARK: - Auto-Adjustment Filters (Deduplicated)

    /// Apply CIImage auto-adjustment filters to produce an enhanced image.
    /// Used by auto-enhance, enhanced bg-removed variant generation, and 3D adjustment reload.
    nonisolated static func applyAutoAdjustmentFilters(to ciImage: CIImage) -> CIImage {
        let filters = ciImage.autoAdjustmentFilters(options: [
            .enhance: true,
            .redEye: false
        ])
        var result = ciImage
        for filter in filters {
            filter.setValue(result, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                result = output
            }
        }
        return result
    }
}
