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

    /// Viewing mode queued while the image was still loading. Applied once loading finishes.
    private var pendingViewingMode: ImagePresentationComponent.ViewingMode?

    /// Native image dimensions (read from file metadata without decoding)
    private var nativeImageDimensions: CGSize?

    /// The max dimension used for the current displayImage
    private(set) var currentDisplayMaxDimension: CGFloat = 0

    /// Per-window resolution override. When non-nil, this overrides the global
    /// maxImageResolution from AppModel and forces dynamic resolution behavior
    /// even when the global setting is Off. nil = use global setting.
    var resolutionOverride: Int? = nil

    /// Last known window size for resize-triggered reloads
    private var lastWindowSize: CGSize?

    /// Saved window size from a previous session, restored from the enhancement tracker.
    /// Used by PhotoDisplayView for initial window sizing instead of mainWindowSize.
    private(set) var savedWindowSize: CGSize?

    /// Debounce task for window resize
    private var resizeDebounceTask: Task<Void, Never>?

    /// Whether a display image load is currently in progress (prevents concurrent loads)
    private var isLoadingDisplayImage: Bool = false

    /// True during the initial sequential load from start(). Prevents resize-triggered
    /// reloads from interfering with enhancement restoration.
    private(set) var isInitialLoadInProgress: Bool = false

    /// Task for 3D generation (tracked so cleanup can avoid removing the component mid-generation)
    private var generateTask: Task<Void, Never>?

    /// Scale factor for converting window points to texture pixels
    /// (visionOS rendering density + headroom)
    private static let displayScaleFactor: CGFloat = 2.5

    // MARK: - Background Removal State

    /// Current state of background removal processing
    var backgroundRemovalState: BackgroundRemovalState = .original

    /// The original display image before background removal (stored for toggle-back)
    private var originalDisplayImage: UIImage? = nil

    /// The background-removed version of the display image (cached for re-toggle)
    private var backgroundRemovedImage: UIImage? = nil

    /// Task for background removal (tracked so cleanup can cancel it)
    private var backgroundRemovalTask: Task<Void, Never>?

    // MARK: - Visual Adjustments State

    /// Per-image visual adjustments (Current tab values)
    var currentAdjustments: VisualAdjustments = VisualAdjustments()

    /// The auto-enhanced UIImage (result of CIImage.autoAdjustmentFilters applied to raw data).
    /// Stored separately so toggling auto-enhance on/off doesn't require re-processing.
    private var autoEnhancedDisplayImage: UIImage? = nil

    /// Whether auto-enhance is currently being processed
    var isProcessingAutoEnhance: Bool = false

    /// The effective adjustments to apply (per-image if modified, otherwise global defaults)
    var effectiveAdjustments: VisualAdjustments {
        if currentAdjustments.isModified {
            return currentAdjustments
        }
        return appModel.globalVisualAdjustments
    }

    /// Whether to show the adjustments popover (driven from ornament button)
    var showAdjustmentsPopover: Bool = false

    // MARK: - Image Flip State

    /// Whether the image is horizontally flipped (showing its "back side")
    var isImageFlipped: Bool = false

    /// Toggle the flip state and persist it via the enhancement tracker.
    func toggleFlip() {
        recordInteraction()
        isImageFlipped.toggle()
        Task {
            await trackFlipState()
        }
    }

    /// Persist the current flip state to the enhancement tracker.
    private func trackFlipState() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setFlipped(url: imageURL, isFlipped: isImageFlipped)
    }

    /// Persist the current resolution override to the enhancement tracker.
    private func trackResolutionOverride() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setResolutionOverride(url: imageURL, resolution: resolutionOverride)
    }

    /// Persist the current window size to the enhancement tracker.
    private func trackWindowSize(_ size: CGSize) async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setWindowSize(url: imageURL, size: size)
    }

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
        if autoEnhancedDisplayImage != nil {
            // Restore the non-enhanced display image
            autoEnhancedDisplayImage = nil
            currentDisplayMaxDimension = 0
            if !is3DMode, !isAnimatedGIF, let windowSize = lastWindowSize {
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
        Task { await trackAdjustments() }
    }

    /// Toggle auto-enhance: applies CIImage auto-adjustment filters to generate
    /// an enhanced base image. Manual sliders (brightness/contrast/saturation) are
    /// applied as SwiftUI view modifiers on top of this base.
    func toggleAutoEnhance() async {
        recordInteraction()
        guard !isProcessingAutoEnhance else { return }

        if currentAdjustments.isAutoEnhanced {
            // Turn off: clear enhanced image, revert to normal displayImage pipeline
            currentAdjustments.isAutoEnhanced = false
            autoEnhancedDisplayImage = nil
            if !is3DMode, !isAnimatedGIF, let windowSize = lastWindowSize {
                currentDisplayMaxDimension = 0
                await loadDisplayImage(for: windowSize)
            }
        } else {
            // Turn on: apply CIImage auto-adjustment
            isProcessingAutoEnhance = true

            guard let imageData = currentImageData,
                  let ciImage = CIImage(data: imageData) else {
                isProcessingAutoEnhance = false
                return
            }

            // Run auto-enhancement off the main thread
            let enhanced = await Task.detached { () -> UIImage? in
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

                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let cgImage = context.createCGImage(result, from: result.extent) else { return nil }
                return UIImage(cgImage: cgImage)
            }.value

            guard let enhanced else {
                isProcessingAutoEnhance = false
                return
            }

            // Downscale for display (respects current resolution settings)
            let windowSize = lastWindowSize ?? appModel.mainWindowSize
            let displayVersion = await Task.detached { [windowSize] () -> UIImage? in
                let maxDim = max(windowSize.width, windowSize.height) * 2.5
                let sourceSize = enhanced.size
                let nativeMaxDim = max(sourceSize.width, sourceSize.height)
                let targetDim = min(maxDim, nativeMaxDim)

                let scale = targetDim / nativeMaxDim
                if scale >= 0.95 { return enhanced }

                let newSize = CGSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )
                let renderer = UIGraphicsImageRenderer(size: newSize)
                return renderer.image { _ in
                    enhanced.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }.value

            autoEnhancedDisplayImage = displayVersion
            if !is3DMode, !isAnimatedGIF {
                displayImage = displayVersion
            }
            currentAdjustments.isAutoEnhanced = true
            isProcessingAutoEnhance = false
        }

        Task { await trackAdjustments() }
    }

    /// Persist the current visual adjustments to the enhancement tracker.
    func trackAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setAdjustments(
            url: imageURL, adjustments: currentAdjustments.isModified ? currentAdjustments : nil
        )
    }

    /// Restore saved visual adjustments for the current image.
    private func restoreAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        if let savedAdjustments = await ImageEnhancementTracker.shared.adjustments(url: imageURL) {
            currentAdjustments = savedAdjustments
            if savedAdjustments.isAutoEnhanced && !is3DMode && !isAnimatedGIF {
                await toggleAutoEnhance()
            }
        }
    }

    // MARK: - Idle Downscale State

    /// Timestamp of the last user interaction with this window.
    /// Used by AppModel's LRU memory pressure system to determine which
    /// windows to downscale first (least-recently-interacted = first evicted).
    private(set) var lastInteractionTime: Date = Date()

    /// Whether this window has been downscaled due to memory pressure.
    /// When true, the display image is at thumbnail resolution and raw data
    /// has been released. Restored on next user interaction.
    private(set) var isIdleDownscaled: Bool = false

    /// True while `restoreFromIdleDownscale` is running async work.
    /// Prevents memory-pressure from immediately re-downscaling this window.
    private(set) var isRestoringFromIdle: Bool = false

    /// Max dimension used for idle-downscaled thumbnail display
    private static let idleDownscaleDimension: CGFloat = 256

    // MARK: - Scene Phase Idle Downscale

    /// Task that fires after the inactivity timeout to downscale the window
    private var scenePhaseIdleTask: Task<Void, Never>?

    /// How long a window must remain inactive/background before being downscaled
    private static let scenePhaseIdleTimeout: TimeInterval = 5 * 60 // 5 minutes

    /// Whether this window is in the user's current room (scene phase is active).
    /// Used by AppModel's memory pressure system to prioritize downscaling
    /// windows in inactive rooms before touching windows the user can see.
    private(set) var isInActiveRoom: Bool = true

    /// Display name for this window used in log messages
    private var displayName: String {
        image.title ?? image.fullSizeURL.deletingPathExtension().lastPathComponent
    }

    /// Handle a scenePhase transition for this window.
    /// Starts an inactivity timer when leaving active, restores on return.
    func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        AppLogger.photoWindow.info(
            "[\(self.displayName, privacy: .public)] scenePhase: \(Self.phaseLabel(oldPhase), privacy: .public) → \(Self.phaseLabel(newPhase), privacy: .public)"
        )

        if newPhase == .active {
            isInActiveRoom = true

            // Window became visible again — cancel any pending downscale and restore
            scenePhaseIdleTask?.cancel()
            scenePhaseIdleTask = nil

            if isIdleDownscaled {
                AppLogger.photoWindow.info("[\(self.displayName, privacy: .public)] Restoring from scene-phase idle downscale")
                Task {
                    await restoreFromIdleDownscale()
                }
            }
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false

            // Window moved to another room — start inactivity timer
            scheduleScenePhaseIdleDownscale()
        }
    }

    /// Schedule an idle downscale after the timeout period
    private func scheduleScenePhaseIdleDownscale() {
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.scenePhaseIdleTimeout))
            } catch {
                return // Cancelled — window became active again
            }

            guard let self, !Task.isCancelled else { return }
            guard !self.isIdleDownscaled, !self.isRestoringFromIdle else { return }

            AppLogger.photoWindow.info("[\(self.displayName, privacy: .public)] Idle downscaling after scene-phase timeout")
            await self.releaseMemoryForIdleDownscale()
            await self.applyIdleDownscaleThumbnail()
        }
    }

    private static func phaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: - Share State

    var isPreparingShare: Bool = false
    var shareFileURL: URL?

    // MARK: - GIF Support

    var isAnimatedGIF: Bool = false
    var currentImageData: Data? = nil
    var gifHEVCURL: URL? = nil

    // MARK: - UI Visibility State

    var isUIHidden: Bool = false
    var isWindowControlsHidden: Bool = false
    private var autoHideTask: Task<Void, Never>?
    private var windowControlsHideTask: Task<Void, Never>?

    // MARK: - Slideshow State

    enum SlideshowTransitionDirection {
        case next
        case previous
    }

    var isSlideshowActive: Bool = false
    var slideshowImages: [GalleryImage] = []
    var slideshowIndex: Int = 0
    private var slideshowTask: Task<Void, Never>?
    private var slideshowHistory: [GalleryImage] = []

    /// Signal for the view to perform a slide animation during slideshow transitions.
    /// Set by the model, observed and cleared by PhotoDisplayView.
    var slideshowTransitionDirection: SlideshowTransitionDirection? = nil

    /// Task for preloading the next slideshow image data
    private var slideshowPreloadTask: Task<Void, Never>?

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

    /// Pop-out window value for tracking (nil for pushed/shared windows)
    private let popOutWindowValue: PhotoWindowValue?

    /// When true, always use RealityKit's ImagePresentationComponent in mono mode
    /// instead of the lightweight 2D SwiftUI Image. Used by the main window picture
    /// viewer so the 2D-to-3D transition uses RealityKit's built-in animation.
    private let useRealityKitDisplay: Bool

    // MARK: - Initialization

    /// Whether start() has been called (guards against duplicate onAppear calls)
    private var didStart = false

    init(image: GalleryImage, appModel: AppModel, popOutWindowValue: PhotoWindowValue? = nil, useRealityKitDisplay: Bool = false) {
        self.image = image
        self.imageURL = image.fullSizeURL
        self.appModel = appModel
        self.popOutWindowValue = popOutWindowValue
        self.useRealityKitDisplay = useRealityKitDisplay
        self.isLoadingDetailImage = true

        // Capture pagination state for lazy loading (must be before galleryImages access)
        self.imageSource = appModel.imageSource
        self.snapshotFilter = appModel.currentFilter
        self.currentPage = appModel.currentPage
        self.hasMorePages = appModel.hasMorePages
        self.pageSize = appModel.pageSize

        // Capture snapshot of gallery images for navigation
        self.galleryImages = appModel.galleryImages
        self.currentGalleryIndex = galleryImages.firstIndex(of: image) ?? 0

        // NOTE: Side effects (openPhotoWindowCount, image loading Task) are
        // deferred to start() which is called from onAppear.  Putting them here
        // would cause them to fire every time SwiftUI re-creates the view struct,
        // even though @State discards the duplicate model.
    }

    /// Call once from onAppear to register the window and begin loading.
    func start() {
        guard !didStart else { return }
        didStart = true
        isInitialLoadInProgress = true

        appModel.openPhotoWindowCount += 1
        appModel.registerWindowModel(self)
        lastInteractionTime = Date()

        // Register pop-out window for duplicate detection
        if let windowValue = popOutWindowValue {
            appModel.registerPopOutWindow(imageURL: imageURL, windowValue: windowValue)
        }

        // Sequential load: resolution restore → window size restore → data → enhancement check → 2D fallback → flip restore
        Task {
            // Restore per-image settings before any image loading
            if appModel.rememberImageEnhancements {
                let savedOverride = await ImageEnhancementTracker.shared.resolutionOverride(url: imageURL)
                if savedOverride != nil {
                    resolutionOverride = savedOverride
                }
                let savedSize = await ImageEnhancementTracker.shared.windowSize(url: imageURL)
                if let savedSize {
                    savedWindowSize = savedSize
                    lastWindowSize = savedSize
                }
            }
            await loadImageDataForDetail(url: imageURL)
            // If no enhancement was applied and it's not a GIF, load 2D display image
            if !isAnimatedGIF && !is3DMode && backgroundRemovalState == .original {
                let windowSize = lastWindowSize ?? appModel.mainWindowSize
                await loadDisplayImage(for: windowSize)
            }
            // Restore flip state (independent of other enhancements, but not for 3D/RealityKit)
            if appModel.rememberImageEnhancements, !is3DMode {
                let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: imageURL)
                if wasFlipped {
                    isImageFlipped = true
                }
            }
            // Restore visual adjustments
            await restoreAdjustments()
            isInitialLoadInProgress = false
            await applyPendingViewingMode()
        }
    }

    // MARK: - Image Loading

    /// Load image data for the detail view and detect if it's an animated GIF.
    /// Pass autoRestore: false when calling from loadDisplayImage — that path only
    /// needs the raw data and must not trigger a second concurrent auto-restoration.
    private func loadImageDataForDetail(url: URL, autoRestore: Bool = true) async {
        do {
            if let data = try await ImageLoader.shared.loadRawData(from: url) {
                currentImageData = data
                isAnimatedGIF = data.isAnimatedGIF

                if isAnimatedGIF {
                    // For GIFs, calculate aspect ratio from the image data
                    if let image = UIImage(data: data) {
                        imageAspectRatio = image.size.width / image.size.height
                    }

                    // Show the GIF immediately (base64 fallback) while HEVC converts
                    isLoadingDetailImage = false

                    // Convert GIF to HEVC in background for reliable multi-window playback
                    do {
                        gifHEVCURL = try await GIFHEVCConverter.shared.convert(gifData: data, sourceURL: url)
                    } catch {
                        AppLogger.gifConverter.warning("GIF HEVC conversion failed, falling back to base64: \(error.localizedDescription, privacy: .public)")
                        gifHEVCURL = nil
                    }
                } else if autoRestore {
                    // Check if the image was previously enhanced and auto-restore
                    await autoRestorePreviousEnhancement()
                }
            }
        } catch {
            AppLogger.photoWindow.error("Error loading image data: \(error.localizedDescription, privacy: .public)")
            isLoadingDetailImage = false
        }
    }

    /// Record an enhancement in the tracker, but only if the setting is enabled.
    private func trackViewingMode(_ mode: ViewingModePreference) async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setLastViewingMode(url: imageURL, mode: mode)
    }

    private func trackImageConverted() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.markAsConverted(url: imageURL)
    }

    /// Auto-restore the last enhancement (3D or background removal) if applicable.
    /// When useRealityKitDisplay is set, always activates RealityKit in mono mode.
    private func autoRestorePreviousEnhancement() async {
        guard !isAnimatedGIF, !is3DMode else { return }
        guard backgroundRemovalState == .original else { return }

        if useRealityKitDisplay {
            // Always use RealityKit — check if we should also auto-generate 3D
            if appModel.rememberImageEnhancements {
                let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
                let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
                let shouldAutoGenerate = wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive)
                if shouldAutoGenerate && lastMode == .spatial3DImmersive {
                    desiredViewingMode = .spatial3DImmersive
                }
                activate3DMode(generateImmediately: shouldAutoGenerate)
            } else {
                activate3DMode(generateImmediately: false)
            }
            return
        }

        guard appModel.rememberImageEnhancements else { return }

        let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
        let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)

        if wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive) {
            // Auto-activate 3D (skips 2D load entirely)
            if lastMode == .spatial3DImmersive {
                desiredViewingMode = .spatial3DImmersive
            }
            activate3DMode()
        } else if lastMode == .backgroundRemoved {
            if let cachedData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
               let cachedImage = UIImage(data: cachedData) {
                await applyDownscaledCachedBackgroundRemoval(cachedImage)
            } else {
                await performFullResolutionBackgroundRemoval(isAutoDuringLoad: true)
            }
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
        guard backgroundRemovalState == .original else { return }

        lastWindowSize = windowSize

        isLoadingDisplayImage = true
        defer { isLoadingDisplayImage = false }

        // Ensure raw data is downloaded to disk cache.
        // autoRestore: false — auto-restoration runs exclusively from start(), not here.
        if currentImageData == nil {
            await loadImageDataForDetail(url: imageURL, autoRestore: false)
        }
        guard !isAnimatedGIF else { return }
        // autoRestorePreviousEnhancement may have run inside loadImageDataForDetail —
        // abort the 2D load if an enhancement is now active
        guard backgroundRemovalState == .original, !is3DMode else { return }

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

        // Calculate target dimension: full native when effective resolution is off (0),
        // otherwise window size × scale factor capped at both max resolution and native.
        // During initial load, use max resolution directly — window size is unreliable
        // during visionOS scene restoration and the resize handler will adjust later.
        let effectiveRes = effectiveMaxResolution
        let targetDimension: CGFloat
        if effectiveRes > 0 {
            let maxRes = CGFloat(effectiveRes)
            if isInitialLoadInProgress {
                targetDimension = min(maxRes, nativeMaxDim)
            } else {
                targetDimension = min(
                    max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
                    maxRes,
                    nativeMaxDim
                )
            }
        } else {
            targetDimension = nativeMaxDim
        }

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

        // Re-check after off-thread downsampling: an enhancement may have been applied
        // concurrently (e.g., from the start() task running in parallel with this load)
        guard backgroundRemovalState == .original, !is3DMode else {
            isLoadingDetailImage = false
            return
        }

        displayImage = image
        imageAspectRatio = image.size.width / image.size.height
        currentDisplayMaxDimension = targetDimension
        isLoadingDetailImage = false
    }

    /// Auto-restore background removal by applying to the current display image.
    /// Unlike the user-initiated toggle, this processes the already-downsampled display image
    /// to avoid jarring resizes. Only updates in-memory cache (not persistent cache).
    /// Handle window resize with 1-second debounce. Re-downsamples the display
    /// image in memory when the window size changes significantly.
    /// No-op when dynamic image resolution is disabled (already at full res).
    func handleWindowResize(_ newSize: CGSize) {
        // Update LRU timestamp but don't trigger idle-downscale restore.
        // SwiftUI fires geometry changes when content is cleared (e.g. during
        // memory-pressure downscale), which would cause an immediate re-restore.
        lastInteractionTime = Date()
        lastWindowSize = newSize

        // Persist window size (debounced alongside the image reload)
        // This runs for all display modes so the size is remembered even for
        // 3D, GIF, or full-resolution images that skip re-downsampling.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }

            // Persist the window size for this image
            await self.trackWindowSize(newSize)

            // Re-downsample display image if dynamic resolution is active
            guard self.effectiveMaxResolution > 0 else { return }
            guard !self.is3DMode, !self.isAnimatedGIF else { return }
            guard !self.isLoadingDetailImage, !self.isLoadingDisplayImage else { return }
            guard !self.isInitialLoadInProgress else { return }
            guard self.displayImage != nil else { return }

            if self.backgroundRemovalState == .removed {
                await self.reloadBackgroundRemovedAtCurrentResolution()
            } else if self.backgroundRemovalState == .original {
                await self.loadDisplayImage(for: newSize)
            }
        }
    }

    /// Resolve the file URL for the current image (disk cache or original file URL)
    private func resolveSourceFileURL() async -> URL? {
        if imageURL.isFileURL {
            return imageURL
        }
        return await DiskImageCache.shared.cachedFileURL(for: imageURL)
    }

    // MARK: - Interaction Tracking

    /// Record a user interaction with this window. Updates the LRU timestamp
    /// and restores from idle downscale if the window was previously evicted.
    func recordInteraction() {
        lastInteractionTime = Date()

        if isIdleDownscaled {
            Task {
                await restoreFromIdleDownscale()
            }
        }
    }

    // MARK: - Memory Pressure Idle Downscale

    /// Aggressively downscale this window to thumbnail resolution to free memory.
    /// Called by AppModel's LRU memory pressure system. Ignores resolution overrides
    /// since crash prevention is more important than user preferences.
    /// Phase 1: Release all heavy in-memory resources without allocating anything new.
    /// This is safe to call during memory pressure since it only frees memory.
    /// After this, the window may show a stale display image or blank until
    /// `applyIdleDownscaleThumbnail()` replaces it with a small thumbnail.
    func releaseMemoryForIdleDownscale() async {
        guard !isIdleDownscaled, !isRestoringFromIdle else { return }

        AppLogger.photoWindow.info("Releasing memory for idle downscale")

        // If in 3D mode, release RealityKit textures (GPU memory)
        if is3DMode {
            // Cancel any in-progress 3D generation first (RealityKit crashes otherwise)
            if let task = generateTask {
                task.cancel()
                await task.value
                generateTask = nil
            }
            spatial3DImage = nil
            spatial3DImageState = .notGenerated
            pendingGenerate3D = false
            contentEntity.components.remove(ImagePresentationComponent.self)
            is3DMode = false
        }

        // Clear background removal caches
        clearBackgroundRemovalState()

        // Release raw image data (can be reloaded from disk cache)
        currentImageData = nil

        // Release current display image to free decoded bitmap memory
        displayImage = nil
        autoEnhancedDisplayImage = nil

        // For GIFs, release HEVC converted data too
        if isAnimatedGIF {
            gifHEVCURL = nil
        }

        isIdleDownscaled = true
    }

    /// Phase 2: Load a small thumbnail so the window shows a recognizable preview
    /// instead of blank. Called after `releaseMemoryForIdleDownscale()` has freed
    /// memory from all targeted windows first.
    ///
    /// Tries sources in order of efficiency:
    /// 1. ThumbnailCache (pre-generated HEIC on disk, cheapest to load)
    /// 2. CGImageSource downsample from the full-res cached file
    func applyIdleDownscaleThumbnail() async {
        guard isIdleDownscaled else { return }
        // GIFs and windows with no display don't need a thumbnail
        guard !isAnimatedGIF else { return }

        let thumbnailDim = Self.idleDownscaleDimension

        // Try the pre-generated thumbnail cache first (tiny HEIC files, no decode of full image)
        if let cached = await ThumbnailCache.shared.loadThumbnail(for: imageURL) {
            displayImage = cached
            imageAspectRatio = cached.size.width / cached.size.height
            currentDisplayMaxDimension = thumbnailDim
            return
        }

        // Fall back to CGImageSource downsample from the disk-cached full-res file
        guard let sourceURL = await resolveSourceFileURL() else { return }

        let image = await Task.detached { [sourceURL, thumbnailDim] in
            ThumbnailGenerator.shared.downsampleImage(at: sourceURL, maxDimension: thumbnailDim)
        }.value

        if let image {
            displayImage = image
            imageAspectRatio = image.size.width / image.size.height
            currentDisplayMaxDimension = thumbnailDim
        }
    }

    /// Restore this window from idle-downscaled state to proper resolution.
    /// Called when the user interacts with a previously downscaled window.
    func restoreFromIdleDownscale() async {
        guard isIdleDownscaled else { return }

        AppLogger.photoWindow.info("[\(self.displayName, privacy: .public)] Restoring window from idle downscale")
        isRestoringFromIdle = true
        isIdleDownscaled = false
        currentDisplayMaxDimension = 0
        isLoadingDetailImage = true

        // Update interaction time so this window isn't the oldest LRU target
        // if memory pressure fires during the restore
        lastInteractionTime = Date()

        let windowSize = lastWindowSize ?? appModel.mainWindowSize

        // Reload raw data and display image via the standard path
        await loadImageDataForDetail(url: imageURL)

        if !isAnimatedGIF && !is3DMode && backgroundRemovalState == .original {
            await loadDisplayImage(for: windowSize)
        }

        // Restore flip state
        if appModel.rememberImageEnhancements, !is3DMode {
            let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: imageURL)
            if wasFlipped {
                isImageFlipped = true
            }
        }

        // Restore visual adjustments (re-processes auto-enhance if needed)
        if currentAdjustments.isAutoEnhanced && !is3DMode && !isAnimatedGIF {
            let wasAutoEnhanced = currentAdjustments.isAutoEnhanced
            currentAdjustments.isAutoEnhanced = false
            if wasAutoEnhanced {
                await toggleAutoEnhance()
            }
        }

        isLoadingDetailImage = false
        isRestoringFromIdle = false
    }

    // MARK: - Lightweight Display Transition

    /// Transition from RealityKit to lightweight SwiftUI display.
    /// Called when memory warning triggers lightweight mode.
    func switchToLightweightDisplay() async {
        guard !isAnimatedGIF else { return }

        // If 3D generation is in progress, wait for it to finish before
        // removing the component (RealityKit crashes otherwise)
        if let task = generateTask {
            task.cancel()
            await task.value
            generateTask = nil
        }

        // Release RealityKit resources immediately to free memory
        spatial3DImage = nil
        spatial3DImageState = .notGenerated
        pendingGenerate3D = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        is3DMode = false
        clearBackgroundRemovalState()

        // Reset display dimension so loadDisplayImage doesn't early-exit
        currentDisplayMaxDimension = 0

        // Load lightweight display image
        isLoadingDetailImage = true
        if let windowSize = lastWindowSize {
            await loadDisplayImage(for: windowSize)
        }
    }

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
        // Initialize to mono unless already targeting immersive (e.g. auto-restore)
        if desiredViewingMode != .spatial3DImmersive {
            desiredViewingMode = .mono
        }
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
                    guard var ipc = self.contentEntity.components[ImagePresentationComponent.self] else { return }
                    ipc.desiredViewingMode = .spatial3DImmersive
                    self.desiredViewingMode = .spatial3DImmersive
                    self.contentEntity.components.set(ipc)
                    if let ar = ipc.aspectRatio(for: .spatial3DImmersive) {
                        self.imageAspectRatio = CGFloat(ar)
                    }
                    self.immersiveResizeTrigger += 1
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

    /// Trigger for immersive window resize (incremented when entering/exiting immersive)
    var immersiveResizeTrigger: Int = 0

    /// Window size before entering immersive mode (for restoration)
    var preImmersiveWindowSize: CGSize? = nil

    /// The desired viewing mode (set immediately, before RealityKit animation completes)
    var desiredViewingMode: ImagePresentationComponent.ViewingMode = .mono

    /// Whether this model always uses RealityKit for display (even in 2D/mono mode)
    var isRealityKitDisplay: Bool { useRealityKitDisplay }

    /// The effective max resolution for this window, considering per-window override.
    /// When resolutionOverride is set, it takes priority over the global setting.
    /// A value of 0 means "Off" (full native resolution).
    var effectiveMaxResolution: Int {
        resolutionOverride ?? appModel.maxImageResolution
    }

    /// The current display resolution in pixels (longest edge of the displayed image).
    /// Returns 0 when no display image is loaded (e.g., in 3D mode or loading).
    var currentDisplayResolution: Int {
        guard let image = displayImage else { return 0 }
        return Int(max(image.size.width, image.size.height))
    }

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

        guard backgroundRemovalState == .original else { return }

        // Reset current dimension to force reload
        currentDisplayMaxDimension = 0
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        await loadDisplayImage(for: windowSize)
    }

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
                guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                ipc.desiredViewingMode = .spatial3DImmersive
                desiredViewingMode = .spatial3DImmersive
                contentEntity.components.set(ipc)
                if let ar = ipc.aspectRatio(for: .spatial3DImmersive) { imageAspectRatio = CGFloat(ar) }
                immersiveResizeTrigger += 1
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            } else {
                guard var ipc = contentEntity.components[ImagePresentationComponent.self] else { return }
                guard ipc.viewingMode != .spatial3DImmersive else { return }
                ipc.desiredViewingMode = .spatial3DImmersive
                desiredViewingMode = .spatial3DImmersive
                contentEntity.components.set(ipc)
                if let ar = ipc.aspectRatio(for: .spatial3DImmersive) { imageAspectRatio = CGFloat(ar) }
                immersiveResizeTrigger += 1
                Task { await self.trackViewingMode(.spatial3DImmersive) }
            }
        }
    }

    /// Apply a viewing mode that was queued while the image was loading.
    private func applyPendingViewingMode() async {
        guard let mode = pendingViewingMode else { return }
        pendingViewingMode = nil
        guard !isAnimatedGIF else { return }
        await switchToViewingMode(mode)
    }

    /// Check if the current image was previously converted and auto-generate if so
    private func autoGenerateSpatial3DIfPreviouslyConverted() async {
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

    // MARK: - Background Removal

    /// Toggle background removal: original -> remove, removing -> cancel, removed -> restore.
    func toggleBackgroundRemoval() async {
        recordInteraction()
        switch backgroundRemovalState {
        case .original:
            // First check in-memory cache
            if let cached = backgroundRemovedImage {
                originalDisplayImage = displayImage
                displayImage = cached
                backgroundRemovalState = .removed
            } else {
                // Then check persistent cache (full-res version)
                if let cachedData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
                   let cachedImage = UIImage(data: cachedData) {
                    // Downscale the full-res cached version for display
                    await applyDownscaledCachedBackgroundRemoval(cachedImage)
                } else {
                    // No cache, process the full-resolution image
                    await performFullResolutionBackgroundRemoval(isAutoDuringLoad: false)
                }
            }
        case .removing:
            backgroundRemovalTask?.cancel()
            backgroundRemovalTask = nil
            backgroundRemovalState = .original
            await trackViewingMode(.mono)
        case .removed:
            restoreOriginalBackground()
        }
    }

    /// Process background removal on the full-resolution image.
    /// Caches the full-res result, then downscales for display.
    private func performFullResolutionBackgroundRemoval(isAutoDuringLoad: Bool) async {
        guard let imageData = currentImageData else {
            AppLogger.photoWindow.warning("No image data available for full-resolution background removal")
            return
        }

        // Load full-resolution image
        guard let fullResImage = UIImage(data: imageData) else {
            AppLogger.photoWindow.warning("Failed to create UIImage from data for background removal")
            return
        }

        backgroundRemovalState = .removing

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let processed = try await BackgroundRemover.shared.removeBackground(from: fullResImage)

                guard !Task.isCancelled else {
                    self.backgroundRemovalState = .original
                    return
                }

                if let processed {
                    // Cache the full-resolution background-removed image
                    await BackgroundRemovalCache.shared.saveImage(processed, for: self.imageURL)

                    // Now downscale the result for display
                    let displayImage = await self.downscaleForDisplay(processed)

                    self.backgroundRemovedImage = displayImage
                    self.originalDisplayImage = self.displayImage
                    self.displayImage = displayImage
                    self.imageAspectRatio = displayImage.size.width / displayImage.size.height
                    self.backgroundRemovalState = .removed

                    await self.trackViewingMode(.backgroundRemoved)
                } else {
                    self.backgroundRemovalState = isAutoDuringLoad ? .original : .original
                    AppLogger.photoWindow.warning("Background removal returned nil")
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.photoWindow.error("Background removal failed: \(error.localizedDescription, privacy: .public)")
                    self.backgroundRemovalState = .original
                }
            }
        }
        backgroundRemovalTask = task
        await task.value
        backgroundRemovalTask = nil
        isLoadingDetailImage = false
    }

    /// Apply a downscaled version of a cached background-removed image.
    private func applyDownscaledCachedBackgroundRemoval(_ fullResImage: UIImage) async {
        backgroundRemovalState = .removing

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Downscale the full-res cached version for display
            let displayImage = await self.downscaleForDisplay(fullResImage)

            guard !Task.isCancelled else {
                self.backgroundRemovalState = .original
                return
            }

            self.backgroundRemovedImage = displayImage
            self.originalDisplayImage = self.displayImage
            self.displayImage = displayImage
            self.imageAspectRatio = displayImage.size.width / displayImage.size.height
            self.backgroundRemovalState = .removed

            await self.trackViewingMode(.backgroundRemoved)
        }
        backgroundRemovalTask = task
        await task.value
        backgroundRemovalTask = nil
        isLoadingDetailImage = false
    }

    /// Downscale an image for display using the same strategy as loadDisplayImage.
    /// Mirrors the target-dimension logic: min(windowSize × scale, maxRes, nativeMax).
    private func downscaleForDisplay(_ image: UIImage) async -> UIImage {
        let effectiveRes = effectiveMaxResolution
        // If dynamic resolution is disabled, use the image as-is
        guard effectiveRes > 0 else {
            return image
        }

        let maxRes = CGFloat(effectiveRes)
        let imageWidth = image.size.width
        let imageHeight = image.size.height
        let nativeMaxDim = max(imageWidth, imageHeight)

        // Match loadDisplayImage: window size × scale, capped at max resolution and native
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        let targetDimension = min(
            max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
            maxRes,
            nativeMaxDim
        )

        guard nativeMaxDim > targetDimension else {
            return image // Already smaller than target, no downsampling needed
        }

        // Create a new UIImage at the downsampled size
        let scaleFactor = targetDimension / nativeMaxDim
        let newSize = CGSize(
            width: imageWidth * scaleFactor,
            height: imageHeight * scaleFactor
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Reload the background-removed image at the current effective resolution.
    /// Fetches the full-res cached version from disk and re-downscales it.
    private func reloadBackgroundRemovedAtCurrentResolution() async {
        guard backgroundRemovalState == .removed else { return }

        // Try to load the full-res background-removed image from persistent cache
        guard let cachedData = await BackgroundRemovalCache.shared.loadData(for: imageURL),
              let fullResImage = UIImage(data: cachedData) else {
            AppLogger.photoWindow.warning("Cannot reload background-removed image: no cached data")
            return
        }

        let downscaled = await downscaleForDisplay(fullResImage)
        backgroundRemovedImage = downscaled
        displayImage = downscaled
        imageAspectRatio = downscaled.size.width / downscaled.size.height
    }

    private func restoreOriginalBackground() {
        backgroundRemovalState = .original
        Task {
            await trackViewingMode(.mono)
        }
        if let original = originalDisplayImage {
            displayImage = original
        } else {
            // Auto-restore case: originalDisplayImage was nil because displayImage hadn't loaded yet
            // when background removal ran. Clear displayImage so PhotoDisplayView triggers a fresh load.
            displayImage = nil
            if let windowSize = lastWindowSize {
                isLoadingDetailImage = true
                Task { await loadDisplayImage(for: windowSize) }
            }
        }
    }

    private func clearBackgroundRemovalState() {
        backgroundRemovalTask?.cancel()
        backgroundRemovalTask = nil
        backgroundRemovalState = .original
        originalDisplayImage = nil
        backgroundRemovedImage = nil
    }

    // MARK: - Share

    func shareImage() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        let url = image.fullSizeURL
        // Prefer server filename (has correct extension), fall back to title
        let shareName = image.fileName ?? image.title

        if url.isFileURL {
            presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: url, title: shareName, originalURL: url))
            return
        }

        // Remote URL — check disk cache first, otherwise download
        if let cachedURL = await DiskImageCache.shared.cachedFileURL(for: url) {
            presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: cachedURL, title: shareName, originalURL: url))
            return
        }

        // Download the full-res image (also caches to disk)
        do {
            _ = try await ImageLoader.shared.loadRawData(from: url)
            if let cachedURL = await DiskImageCache.shared.cachedFileURL(for: url) {
                presentShareSheet(url: ShareSheetHelper.prepareShareFile(from: cachedURL, title: shareName, originalURL: url))
            }
        } catch {
            AppLogger.photoWindow.error("Failed to download image for sharing: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func presentShareSheet(url: URL) {
        cancelAutoHideTimer()
        shareFileURL = url
    }

    // MARK: - UI Auto-Hide

    func startAutoHideTimer() {
        recordInteraction()
        cancelAutoHideTimer()

        guard appModel.autoHideDelay > 0 else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled {
                isUIHidden = true
                // Schedule window controls to hide 1.5 seconds later
                scheduleWindowControlsHiding()
            }
        }
    }

    private func scheduleWindowControlsHiding() {
        windowControlsHideTask?.cancel()
        windowControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isWindowControlsHidden = true
            }
        }
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        isWindowControlsHidden = false
    }

    func toggleUIVisibility() {
        recordInteraction()
        isUIHidden.toggle()
        isWindowControlsHidden = false
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Slideshow

    /// Start a random slideshow in this window
    func startSlideshow() async {
        recordInteraction()
        guard !isSlideshowActive else { return }

        isSlideshowActive = true
        slideshowHistory = [image]  // Start with current image in history
        slideshowImages = []
        slideshowIndex = 0

        // Fetch initial batch of random images (no seed for true randomness)
        await fetchRandomSlideshowImages()

        // Preload the first slideshow image so it's ready when the timer fires
        preloadNextSlideshowImage()

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
                    advanceSlideshow()
                }
            }
        }
    }

    /// Signal the view to animate to the next slideshow image
    private func advanceSlideshow() {
        // Don't queue another transition if one is already in progress
        guard slideshowTransitionDirection == nil else { return }
        slideshowTransitionDirection = .next
    }

    /// Switch to displaying a different image
    private func switchToImage(_ newImage: GalleryImage) async {
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
        currentImageData = nil
        gifHEVCURL = nil
        displayImage = nil
        nativeImageDimensions = nil
        currentDisplayMaxDimension = 0
        isLoadingDisplayImage = false
        contentEntity.components.remove(ImagePresentationComponent.self)
        clearBackgroundRemovalState()

        // Reset to 2D mode when switching images (RealityView will be recreated
        // if needed when activate3DMode sets is3DMode back to true)
        is3DMode = false
        desiredViewingMode = .mono
        isImageFlipped = false
        resolutionOverride = nil
        currentAdjustments = VisualAdjustments()
        autoEnhancedDisplayImage = nil

        // Restore per-image settings before loading
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

        // Load image data to detect if it's a GIF
        await loadImageDataForDetail(url: newImage.fullSizeURL)

        // Load 2D display image if not a GIF and not using RealityKit display
        // (useRealityKitDisplay images go through autoRestorePreviousEnhancement → activate3DMode)
        if !isAnimatedGIF && !useRealityKitDisplay, let windowSize = lastWindowSize {
            await loadDisplayImage(for: windowSize)
        }

        // Restore flip state (independent of other enhancements, but not for 3D/RealityKit)
        if appModel.rememberImageEnhancements, !is3DMode {
            let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: newImage.fullSizeURL)
            if wasFlipped {
                isImageFlipped = true
            }
        }

        // Restore visual adjustments for the new image
        await restoreAdjustments()

        await applyPendingViewingMode()
    }

    /// Perform the actual slideshow image switch (called by the view during animation phase 2).
    func performSlideshowSwitch(direction: SlideshowTransitionDirection) async {
        switch direction {
        case .next:
            slideshowIndex += 1
            if slideshowIndex >= slideshowImages.count {
                await fetchRandomSlideshowImages()
                slideshowIndex = 0
            }
            if slideshowIndex < slideshowImages.count {
                let nextImage = slideshowImages[slideshowIndex]
                await switchToImage(nextImage)
                slideshowHistory.append(nextImage)
            }
        case .previous:
            guard slideshowHistory.count > 1 else { return }
            slideshowHistory.removeLast()
            if let previousImage = slideshowHistory.last {
                await switchToImage(previousImage)
            }
        }
    }

    /// Called by the view after the slideshow transition animation finishes.
    func slideshowTransitionCompleted() {
        slideshowTransitionDirection = nil
        preloadNextSlideshowImage()
    }

    /// Preload the next slideshow image data into disk cache for instant display.
    private func preloadNextSlideshowImage() {
        slideshowPreloadTask?.cancel()

        let nextIndex = slideshowIndex + 1
        guard nextIndex < slideshowImages.count else {
            // Next image requires a new batch fetch — skip preload for this one
            return
        }

        let imageToPreload = slideshowImages[nextIndex]
        slideshowPreloadTask = Task { @MainActor in
            do {
                _ = try await ImageLoader.shared.loadRawData(from: imageToPreload.fullSizeURL)
                AppLogger.photoWindow.debug("Preloaded next slideshow image")
            } catch {
                AppLogger.photoWindow.debug("Slideshow preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Go to the next slideshow image manually
    func nextSlideshowImage() {
        guard isSlideshowActive, slideshowTransitionDirection == nil else { return }
        startSlideshowTimer()
        slideshowTransitionDirection = .next
    }

    /// Go to the previous slideshow image
    func previousSlideshowImage() {
        guard isSlideshowActive, slideshowHistory.count > 1, slideshowTransitionDirection == nil else { return }
        startSlideshowTimer()
        slideshowTransitionDirection = .previous
    }

    /// Stop the slideshow
    func stopSlideshow() {
        isSlideshowActive = false
        slideshowTask?.cancel()
        slideshowTask = nil
        slideshowPreloadTask?.cancel()
        slideshowPreloadTask = nil
        slideshowTransitionDirection = nil
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
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
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

        pendingViewingMode = nil

        // Release Spatial3DImage GPU texture
        spatial3DImage = nil
        spatial3DImageState = .notGenerated

        // Release image data
        currentImageData = nil
        gifHEVCURL = nil
        displayImage = nil
        autoEnhancedDisplayImage = nil
        clearBackgroundRemovalState()

        // Only remove the component if generation is NOT active.
        // If active, the entity retains the component until ARC releases both.
        if !generationActive {
            contentEntity.components.remove(ImagePresentationComponent.self)
        }

        // Clear collection references
        galleryImages = []
        slideshowImages = []
        slideshowHistory = []

        // Unregister pop-out window
        if let windowValue = popOutWindowValue {
            appModel.unregisterPopOutWindow(imageURL: imageURL, windowValueId: windowValue.id)
        }

        if didStart {
            appModel.unregisterWindowModel(self)
            appModel.openPhotoWindowCount -= 1
        }
    }

    // MARK: - Gallery Navigation

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
