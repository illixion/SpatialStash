/*
 Spatial Stash - Photo Window Model

 Per-window model for individual photo display windows.
 Each photo window gets its own instance with independent state.

 Memory strategy: Windows open in lightweight 2D mode using a downsampled
 UIImage via SwiftUI Image. RealityKit (full resolution) is only loaded when
 the user explicitly activates 3D. On window resize, the 2D display image
 is re-downsampled in memory (no temp files on disk).
 */

import ImageIO
import Metal
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
    /// Whether to show the auto-restore 3D overlay with cancel button
    var showAutoRestoreOverlay: Bool = false
    var isLoadingDetailImage: Bool = false
    var inputPlaneEntity: Entity = Entity()

    // MARK: - 2D Display Image State

    /// GPU-private texture for lightweight 2D display (nil when in 3D mode).
    /// Preferred over displayImage — lives in GPU memory, not counted as dirty CPU pages.
    var displayTexture: MTLTexture? = nil

    /// Downsampled UIImage for lightweight 2D display.
    /// Only used as a fallback for idle-downscale thumbnails and 3D adjustment previews.
    var displayImage: UIImage? = nil

    /// Whether the window is showing the RealityKit 3D view
    var is3DMode: Bool = false

    /// Set when user taps "Generate 3D" from 2D mode — the RealityView
    /// init closure will consume this flag and start generation.
    var pendingGenerate3D: Bool = false

    /// Viewing mode queued while the image was still loading. Applied once loading finishes.
    var pendingViewingMode: ImagePresentationComponent.ViewingMode?

    /// Native image dimensions (read from file metadata without decoding)
    var nativeImageDimensions: CGSize?

    /// The max dimension used for the current displayImage
    var currentDisplayMaxDimension: CGFloat = 0

    /// Per-window resolution override. When non-nil, this overrides the global
    /// maxImageResolution from AppModel and forces dynamic resolution behavior
    /// even when the global setting is Off. nil = use global setting.
    var resolutionOverride: Int? = nil

    /// Last known window size for resize-triggered reloads
    var lastWindowSize: CGSize?

    /// Saved window size from a previous session, restored from the enhancement tracker.
    /// Used by PhotoDisplayView for initial window sizing instead of mainWindowSize.
    var savedWindowSize: CGSize?

    /// Debounce task for window resize
    var resizeDebounceTask: Task<Void, Never>?

    /// Whether a display image load is currently in progress (prevents concurrent loads)
    var isLoadingDisplayImage: Bool = false

    /// True during the initial sequential load from start(). Prevents resize-triggered
    /// reloads from interfering with enhancement restoration.
    var isInitialLoadInProgress: Bool = false

    /// Task for 3D generation (tracked so cleanup can avoid removing the component mid-generation)
    var generateTask: Task<Void, Never>?

    /// Trigger for immersive window resize (incremented when entering/exiting immersive)
    var immersiveResizeTrigger: Int = 0

    /// Window size before entering immersive mode (for restoration)
    var preImmersiveWindowSize: CGSize? = nil

    /// The desired viewing mode (set immediately, before RealityKit animation completes)
    var desiredViewingMode: ImagePresentationComponent.ViewingMode = .mono

    /// Scale factor for converting window points to texture pixels
    /// (visionOS rendering density + headroom)
    static let displayScaleFactor: CGFloat = 2.5

    // MARK: - Background Removal State

    /// Current state of background removal processing
    var backgroundRemovalState: BackgroundRemovalState = .original

    /// The original display texture before background removal (stored for toggle-back)
    var originalDisplayTexture: MTLTexture? = nil

    /// The background-removed version as a GPU texture (cached for re-toggle)
    var backgroundRemovedTexture: MTLTexture? = nil

    /// The auto-enhanced background-removed version as a GPU texture (cached for re-toggle)
    var autoEnhancedBackgroundRemovedTexture: MTLTexture? = nil

    /// Task for background removal (tracked so cleanup can cancel it)
    var backgroundRemovalTask: Task<Void, Never>?

    // MARK: - Visual Adjustments State

    /// Per-image visual adjustments (Current tab values)
    var currentAdjustments: VisualAdjustments = VisualAdjustments()

    /// In-memory display-resolution auto-enhanced texture (for fast toggle-back)
    var autoEnhancedDisplayTexture: MTLTexture? = nil

    /// The original display texture before auto-enhance was applied (for toggle-back)
    var preAutoEnhanceDisplayTexture: MTLTexture? = nil

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

    /// Whether to show the media info/rating popover (driven from ornament button)
    var showMediaInfoPopover: Bool = false

    /// Whether the view is temporarily showing a 2D preview while 3D adjustments are
    /// being tuned. When true, is3DMode is false and displayImage holds a thumbnail.
    /// The RealityKit component is removed; it gets rebuilt once sliders settle.
    var isShowingAdjustmentPreview: Bool = false

    /// Saved spatial3D generation state before entering adjustment preview mode,
    /// so we know whether to re-generate 3D after the reload.
    var prePreviewSpatial3DState: Spatial3DImageState = .notGenerated

    /// Debounce task for reloading ImagePresentationComponent with adjustments
    var adjustments3DReloadTask: Task<Void, Never>?

    /// Whether any popover is currently open (used to suppress auto-hide timer)
    var hasOpenPopover: Bool {
        showAdjustmentsPopover || showMediaInfoPopover
    }

    // MARK: - Image Flip State

    /// Whether the image is horizontally flipped (showing its "back side")
    var isImageFlipped: Bool = false

    /// Persist the current flip state to the enhancement tracker.
    func trackFlipState() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setFlipped(url: imageURL, isFlipped: isImageFlipped)
    }

    /// Persist the current resolution override to the enhancement tracker.
    func trackResolutionOverride() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setResolutionOverride(url: imageURL, resolution: resolutionOverride)
    }

    /// Persist the current window size to the enhancement tracker.
    func trackWindowSize(_ size: CGSize) async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setWindowSize(url: imageURL, size: size)
    }

    /// Persist the current visual adjustments to the enhancement tracker.
    func trackAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setAdjustments(
            url: imageURL, adjustments: currentAdjustments.isModified ? currentAdjustments : nil
        )
    }

    /// Restore saved visual adjustments (slider values) for the current image.
    /// Auto-enhance restoration is handled separately by autoRestorePreviousEnhancement().
    func restoreAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        guard let savedAdjustments = await ImageEnhancementTracker.shared.adjustments(url: imageURL) else { return }
        currentAdjustments = savedAdjustments
    }

    // MARK: - Idle Downscale State

    /// Timestamp of the last user interaction with this window.
    /// Used by AppModel's LRU memory pressure system to determine which
    /// windows to downscale first (least-recently-interacted = first evicted).
    var lastInteractionTime: Date = Date()

    /// Whether this window has been downscaled due to memory pressure.
    /// When true, the display image is at thumbnail resolution and raw data
    /// has been released. Restored on next user interaction.
    var isIdleDownscaled: Bool = false

    /// True while `restoreFromIdleDownscale` is running async work.
    /// Prevents memory-pressure from immediately re-downscaling this window.
    var isRestoringFromIdle: Bool = false

    /// State captured before idle downscale so restore can skip the full
    /// auto-restore pipeline and directly reload from cache.
    var hadBackgroundRemoval: Bool = false
    var had3DMode: Bool = false
    var hadAutoEnhance: Bool = false

    /// Max dimension used for idle-downscaled thumbnail display
    static let idleDownscaleDimension: CGFloat = 256

    // MARK: - Scene Phase Idle Downscale

    /// Task that fires after the inactivity timeout to downscale the window
    var scenePhaseIdleTask: Task<Void, Never>?

    /// How long a window must remain inactive/background before being downscaled
    static let scenePhaseIdleTimeout: TimeInterval = 5 * 60 // 5 minutes

    /// Whether this window is in the user's current room (scene phase is active).
    /// Used by AppModel's memory pressure system to prioritize downscaling
    /// windows in inactive rooms before touching windows the user can see.
    var isInActiveRoom: Bool = true

    /// Timestamp when this window last left the active room (scene phase
    /// transitioned away from .active). Used by the memory pressure handler
    /// to only downscale windows that have been backgrounded long enough.
    var backgroundedSince: Date?

    /// Display name for this window used in log messages
    var displayName: String {
        image.title ?? image.fullSizeURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Share State

    var isPreparingShare: Bool = false
    var shareFileURL: URL?

    // MARK: - GIF Support

    var isAnimatedGIF: Bool = false
    var isAnimatedWebP: Bool = false
    var isAnimatedWebVisual: Bool = false
    var isAnimatedImage: Bool { isAnimatedGIF || isAnimatedWebP || isAnimatedWebVisual }
    var currentImageData: Data? = nil
    var animatedImageSourceURL: URL? = nil
    var gifHEVCURL: URL? = nil

    // MARK: - UI Visibility State

    var isUIHidden: Bool = false
    var isWindowControlsHidden: Bool = false
    var autoHideTask: Task<Void, Never>?
    var windowControlsHideTask: Task<Void, Never>?

    // MARK: - Gallery Navigation State

    /// Snapshot of gallery images when this window was opened
    var galleryImages: [GalleryImage] = []

    /// Current index in the gallery
    var currentGalleryIndex: Int = 0

    // MARK: - Lazy Loading State

    /// Image source for loading more pages
    let imageSource: any ImageSource

    /// Snapshotted filter from when the window was opened
    let snapshotFilter: ImageFilterCriteria?

    /// Current page for this window's pagination
    var currentPage: Int

    /// Whether there are more pages to load
    var hasMorePages: Bool

    /// Page size for pagination
    let pageSize: Int

    /// Whether a page load is in progress
    var isLoadingMoreImages: Bool = false

    /// How close to the end of the loaded set before triggering a load
    let prefetchThreshold: Int = 5

    // MARK: - Shared References

    var appModel: AppModel

    /// Pop-out window value for tracking (nil for pushed/shared windows)
    let popOutWindowValue: PhotoWindowValue?

    /// When true, always use RealityKit's ImagePresentationComponent in mono mode
    /// instead of the lightweight 2D SwiftUI Image. Used by the main window picture
    /// viewer so the 2D-to-3D transition uses RealityKit's built-in animation.
    let useRealityKitDisplay: Bool

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
        if let texture = displayTexture {
            return max(texture.width, texture.height)
        }
        guard let image = displayImage else { return 0 }
        return Int(max(image.size.width, image.size.height))
    }

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
            if self.appModel.rememberImageEnhancements {
                let savedOverride = await ImageEnhancementTracker.shared.resolutionOverride(url: self.imageURL)
                if savedOverride != nil {
                    self.resolutionOverride = savedOverride
                }
                let savedSize = await ImageEnhancementTracker.shared.windowSize(url: self.imageURL)
                if let savedSize {
                    self.savedWindowSize = savedSize
                    self.lastWindowSize = savedSize
                }
            }
            await self.loadImageDataForDetail(url: self.imageURL)
            // Restore slider values (brightness/contrast/saturation).
            // Auto-enhance restoration is handled by autoRestorePreviousEnhancement()
            // inside loadImageDataForDetail, so the display image is already set if active.
            await self.restoreAdjustments()
            // If no enhancement was applied and it's not a GIF, load 2D display image
            if !self.isAnimatedImage && !self.is3DMode && self.backgroundRemovalState == .original && !self.currentAdjustments.isAutoEnhanced {
                let windowSize = self.lastWindowSize ?? self.appModel.mainWindowSize
                await self.loadDisplayImage(for: windowSize)
            }
            // Restore flip state (independent of other enhancements, but not for 3D/RealityKit)
            if self.appModel.rememberImageEnhancements, !self.is3DMode {
                let wasFlipped = await ImageEnhancementTracker.shared.isFlipped(url: self.imageURL)
                if wasFlipped {
                    self.isImageFlipped = true
                }
            }
            self.isInitialLoadInProgress = false
            await self.applyPendingViewingMode()
        }
    }

    // MARK: - Image Loading

    /// Load image data for the detail view and detect if it's an animated image.
    /// Pass autoRestore: false when calling from loadDisplayImage — that path only
    /// needs the raw data and must not trigger a second concurrent auto-restoration.
    func loadImageDataForDetail(url: URL, autoRestore: Bool = true) async {
        do {
            if let data = try await ImageLoader.shared.loadRawData(from: url) {
                currentImageData = data
                animatedImageSourceURL = await resolveSourceFileURL() ?? url
                isAnimatedGIF = data.isAnimatedGIF
                let fileNameExtension = (image.fileName as NSString?)?.pathExtension.lowercased() ?? ""
                let visualFileType = image.visualFileType ?? ""
                let lowerURL = url.absoluteString.lowercased()
                let isWebPByURL = url.pathExtension.lowercased() == "webp" || lowerURL.contains("webp")
                let isWebPByFileName = fileNameExtension == "webp"
                let isWebPByBytes = data.isWebP
                let isAnimatedWebPByBytes = data.isAnimatedWebP
                isAnimatedWebVisual = visualFileType == "VideoFile"
                // Stash image endpoints often hide the real file extension in the URL.
                // Use the original filename from GraphQL as the format hint, then hand
                // the asset to the browser-based renderer which can display both static
                // and animated WebP correctly.
                isAnimatedWebP = isWebPByFileName || isAnimatedWebPByBytes || isWebPByBytes || isWebPByURL

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
                } else if isAnimatedWebP || isAnimatedWebVisual {
                    if let image = UIImage(data: data) {
                        imageAspectRatio = image.size.width / image.size.height
                    }
                    isLoadingDetailImage = false
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
    func trackViewingMode(_ mode: ViewingModePreference) async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setLastViewingMode(url: imageURL, mode: mode)
    }

    func trackImageConverted() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.markAsConverted(url: imageURL)
    }

    /// Auto-restore the last enhancement (3D or background removal) if applicable.
    /// When useRealityKitDisplay is set, always activates RealityKit in mono mode.
    func autoRestorePreviousEnhancement() async {
        guard !isAnimatedImage, !is3DMode else { return }
        guard backgroundRemovalState == .original else { return }

        if useRealityKitDisplay {
            // Always use RealityKit — check if we should also auto-generate 3D
            if appModel.rememberImageEnhancements {
                let lastMode = await ImageEnhancementTracker.shared.lastViewingMode(url: imageURL)
                let wasConverted = await ImageEnhancementTracker.shared.wasConverted(url: imageURL)
                let shouldAutoGenerate = appModel.autoRestoreSpatial3D && wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive)
                if shouldAutoGenerate {
                    showAutoRestoreOverlay = true
                }
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

        if appModel.autoRestoreSpatial3D && wasConverted && (lastMode == .spatial3D || lastMode == .spatial3DImmersive) {
            // Auto-activate 3D (skips 2D load entirely)
            showAutoRestoreOverlay = true
            if lastMode == .spatial3DImmersive {
                desiredViewingMode = .spatial3DImmersive
            }
            activate3DMode()
        } else if lastMode == .autoEnhanced {
            if let cachedData = await AutoEnhanceCache.shared.loadData(for: imageURL),
               let cachedImage = UIImage(data: cachedData) {
                await applyDownscaledAutoEnhance(cachedImage)
            } else {
                await performFullResolutionAutoEnhance()
            }
        } else if lastMode == .backgroundRemovedAutoEnhanced {
            // Combined state: restore bg removal with auto-enhance active
            currentAdjustments.isAutoEnhanced = true
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
            } else {
                await performFullResolutionBackgroundRemoval(isAutoDuringLoad: true)
            }
        } else if lastMode == .backgroundRemoved {
            if let cachedURL = await BackgroundRemovalCache.shared.cachedFileURL(for: imageURL) {
                await applyCachedBackgroundRemovalFromURL(cachedURL)
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
        guard !isAnimatedImage else { return }
        guard !is3DMode else { return }
        guard !isLoadingDisplayImage else { return }
        guard backgroundRemovalState == .original else { return }
        guard !currentAdjustments.isAutoEnhanced else { return }

        lastWindowSize = windowSize

        isLoadingDisplayImage = true
        defer { isLoadingDisplayImage = false }

        // Ensure raw data is downloaded to disk cache.
        // autoRestore: false — auto-restoration runs exclusively from start(), not here.
        if currentImageData == nil {
            await loadImageDataForDetail(url: imageURL, autoRestore: false)
        }
        guard !isAnimatedImage else { return }
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
        if displayTexture != nil, currentDisplayMaxDimension > 0 {
            let ratio = targetDimension / currentDisplayMaxDimension
            if ratio > 0.8 && ratio < 1.2 {
                return
            }
        }

        // Downsample and upload to GPU texture off main thread.
        // When effective resolution is off (0), force full-quality decode to bypass
        // CGImageSource thumbnail API which can introduce interpolation artifacts.
        let useLossy = appModel.useLossyTextureCompression
        let fullDecode = effectiveRes == 0
        let sendable = await Task.detached { [sourceURL, targetDimension, useLossy, fullDecode] () -> SendableTexture? in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: sourceURL, maxDimension: targetDimension, useLossyCompression: useLossy, forceFullDecode: fullDecode) else { return nil }
            return SendableTexture(texture: tex)
        }.value

        guard let texture = sendable?.texture else {
            AppLogger.photoWindow.warning("Failed to create display texture for image")
            isLoadingDetailImage = false
            return
        }

        // Re-check after off-thread downsampling: an enhancement may have been applied
        // concurrently (e.g., from the start() task running in parallel with this load)
        guard backgroundRemovalState == .original, !is3DMode, !currentAdjustments.isAutoEnhanced else {
            isLoadingDetailImage = false
            return
        }

        displayTexture = texture
        imageAspectRatio = CGFloat(texture.width) / CGFloat(texture.height)
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
        // Skip persistence when in 3D immersive mode — the window is
        // temporarily expanded to fill the field of vision and should
        // not overwrite the user's actual window size.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }

            // Persist the window size for this image (skip during immersive 3D)
            if !self.isViewingSpatial3DImmersive {
                await self.trackWindowSize(newSize)
            }

            // Re-downsample display image if dynamic resolution is active
            guard self.effectiveMaxResolution > 0 else { return }
            guard !self.is3DMode, !self.isAnimatedImage else { return }
            guard !self.isLoadingDetailImage, !self.isLoadingDisplayImage else { return }
            guard !self.isInitialLoadInProgress else { return }
            guard self.displayTexture != nil || self.displayImage != nil else { return }

            if self.backgroundRemovalState == .removed {
                await self.reloadBackgroundRemovedAtCurrentResolution()
            } else if self.currentAdjustments.isAutoEnhanced {
                await self.reloadAutoEnhancedAtCurrentResolution()
            } else if self.backgroundRemovalState == .original {
                await self.loadDisplayImage(for: newSize)
            }
        }
    }

    /// Resolve the file URL for the current image (disk cache or original file URL)
    func resolveSourceFileURL() async -> URL? {
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

    // MARK: - Shared Utilities

    /// Calculate the target dimension for background-removed image downsampling.
    /// Mirrors the logic from loadDisplayImage / downscaleForDisplay.
    func backgroundRemovalTargetDimension() -> CGFloat {
        let effectiveRes = effectiveMaxResolution
        guard effectiveRes > 0 else { return 8192 } // No limit

        let maxRes = CGFloat(effectiveRes)
        if isInitialLoadInProgress {
            return maxRes
        }
        let windowSize = lastWindowSize ?? appModel.mainWindowSize
        return min(
            max(windowSize.width, windowSize.height) * Self.displayScaleFactor,
            maxRes
        )
    }

    /// Downscale an image for display using the same strategy as loadDisplayImage.
    /// Mirrors the target-dimension logic: min(windowSize × scale, maxRes, nativeMax).
    func downscaleForDisplay(_ image: UIImage) async -> UIImage {
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

    /// Downscale a UIImage for display and upload directly to a GPU-private texture.
    /// The intermediate UIImage is freed after upload, keeping only the GPU texture alive.
    func downscaleAndUploadTexture(_ image: UIImage) async -> MTLTexture? {
        let downscaled = await downscaleForDisplay(image)
        let useLossy = appModel.useLossyTextureCompression
        let sendable = await Task.detached { [useLossy] in
            guard let tex = MetalImageRenderer.shared?.createTexture(from: downscaled, useLossyCompression: useLossy) else { return nil as SendableTexture? }
            return SendableTexture(texture: tex)
        }.value
        return sendable?.texture
    }

    // MARK: - Resource Cleanup

    /// Explicitly release large resources when the window is being dismissed.
    /// Ensures GPU textures and image data are freed promptly rather than
    /// waiting for ARC/deinit which may be delayed by SwiftUI state retention.
    func cleanup() {
        // Cancel all tasks
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        adjustments3DReloadTask?.cancel()
        adjustments3DReloadTask = nil

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
        animatedImageSourceURL = nil
        gifHEVCURL = nil
        displayTexture = nil
        displayImage = nil
        isShowingAdjustmentPreview = false
        clearAutoEnhanceState()
        clearBackgroundRemovalState()

        // Only remove the component if generation is NOT active.
        // If active, the entity retains the component until ARC releases both.
        if !generationActive {
            contentEntity.components.remove(ImagePresentationComponent.self)
        }

        // Clear collection references
        galleryImages = []

        // Unregister pop-out window
        if let windowValue = popOutWindowValue {
            appModel.unregisterPopOutWindow(imageURL: imageURL, windowValueId: windowValue.id)
        }

        if didStart {
            appModel.unregisterWindowModel(self)
            appModel.openPhotoWindowCount -= 1
        }
    }
}
