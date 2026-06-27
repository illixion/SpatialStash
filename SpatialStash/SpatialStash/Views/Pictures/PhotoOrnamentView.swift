/*
 Spatial Stash - Photo Ornament View

 Unified ornament for all picture viewer windows.
 Controls are configured via PhotoViewerContext to show/hide
 navigation, slideshow, rating, and context-specific buttons.

 Layout: [Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [Adjustments] | [extras] | [Resolution]

 "Adjustments" opens the image-enhancements popover (brightness/contrast/saturation,
 auto-enhance, background removal, and flip — all unified there). "extras" are
 context-specific icon buttons (Pop Out when pushed, Save when shared).
 */

import RealityKit
import SwiftUI

/// Determines which controls are visible in the photo ornament
enum PhotoViewerContext {
    /// Pushed from gallery grid — back button (dismissWindow), nav, slideshow, 3D, rating, extra buttons
    case pushedFromGallery
    /// Standalone pop-out window — gallery button (openWindow), nav, slideshow, 3D, rating
    case standalone
    /// Shared media viewer — gallery button (openWindow), 3D only
    case shared
}

struct PhotoOrnamentView<ExtraMenuItems: View>: View {
    @Bindable var windowModel: PhotoWindowModel
    let context: PhotoViewerContext
    var onGalleryButtonTap: () -> Void
    @ViewBuilder var extraMenuItems: () -> ExtraMenuItems
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 16) {
            // Gallery / Back button
            Button(action: onGalleryButtonTap) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(context == .pushedFromGallery ? "Pictures" : "Show Gallery")

            Divider()
                .frame(height: 24)

            if context != .shared {
                navigationControls

                Divider()
                    .frame(height: 24)

                slideshowButton

                Divider()
                    .frame(height: 24)
            }

            threeDMenu

            // Info button (rating / metadata — when stashId exists and not shared context)
            if context != .shared, windowModel.image.stashId != nil {
                Divider()
                    .frame(height: 24)

                infoButton
            }

            Divider()
                .frame(height: 24)

            shareButton

            Divider()
                .frame(height: 24)

            adjustmentsButton

            // Context-specific extras (Pop Out / Save). Rendered inline as
            // icon-only buttons — there's at most one in any context, so a
            // dedicated "More" menu would be a single-item drop-down.
            extraMenuItems()
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)

            // Resolution indicator: in 3D mode controls the spatial 3D source
            // resolution; otherwise controls the 2D display resolution.
            if windowModel.is3DMode {
                if !windowModel.isAnimatedImage, windowModel.currentSpatial3DSourceDimension > 0 {
                    resolutionMenu
                }
            } else if !windowModel.isRealityKitDisplay, !windowModel.isAnimatedImage,
                      windowModel.displayTexture != nil || windowModel.displayImage != nil {
                resolutionMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .onChange(of: windowModel.showMediaInfoPopover) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showAdjustmentsPopover) { _, isOpen in
            if isOpen {
                windowModel.cancelAutoHideTimer()
                // Pre-load the preview thumbnail while the user is
                // reaching for the slider so the first slider tick can
                // flip into the 2D preview synchronously. Loading on
                // first slider tick was lossy: continuous drag kept the
                // MainActor busy and the async thumbnail Task's
                // continuation didn't get a chance to run until the
                // drag paused, making the live preview feel like it
                // appeared a beat too late.
                Task { await windowModel.prewarmAdjustmentPreview() }
            } else {
                windowModel.startAutoHideTimer()
                windowModel.clearAdjustmentPreviewIfUnused()
            }
        }
        .onChange(of: show3DPopover) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: showResolutionPopover) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
    }

    // MARK: - Navigation Controls

    @ViewBuilder
    private var navigationControls: some View {
        Button {
            Task {
                await windowModel.previousGalleryImage()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(!windowModel.hasPreviousGalleryImage || windowModel.isLoadingDetailImage)

        if windowModel.isLoadingDetailImage {
            ProgressView()
                .frame(minWidth: 60)
        } else {
            Text("\(windowModel.currentGalleryPosition) / \(windowModel.galleryImageCount)")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(minWidth: 60)
        }

        Button {
            Task {
                await windowModel.nextGalleryImage()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(!windowModel.hasNextGalleryImage || windowModel.isLoadingDetailImage)
    }

    // MARK: - Slideshow Button

    private var slideshowButton: some View {
        Button {
            launchGallerySlideshow()
        } label: {
            Image(systemName: "play.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Slideshow")
    }

    private func launchGallerySlideshow() {
        let appModel = windowModel.appModel
        let config: RemoteViewerConfig
        if let existing = appModel.gallerySlideshowConfig {
            config = existing
        } else {
            var newConfig = RemoteViewerConfig(name: "Gallery Slideshow")
            newConfig.apiEndpoint = ""
            appModel.applySlideshowDefaults(to: &newConfig)
            appModel.gallerySlideshowConfig = newConfig
            config = newConfig
        }
        appModel.pendingGallerySlideshowSource = GallerySlideshowSourceOverride(
            imageSource: windowModel.imageSource,
            filter: windowModel.snapshotFilter
        )
        appModel.enqueueRemoteViewerOpen(configId: config.id)
    }

    // MARK: - 3D Menu

    @State private var show3DPopover = false

    private var threeDMenu: some View {
        Button {
            show3DPopover.toggle()
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: threeDMenuIcon)
                }
            }
            .font(.title3)
            .padding(6)
            .background(isAnyAlternateModeActive ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedImage)
        .help("3D")
        .onChange(of: show3DPopover) { _, isOpen in
            updateOrnamentMenuCount(opened: isOpen)
        }
        .popover(isPresented: $show3DPopover) {
            VStack(spacing: 4) {
                popoverMenuButton(
                    title: "3D",
                    icon: "spatial.capture.fill",
                    isChecked: windowModel.desiredViewingMode == .spatial3D,
                    isDisabled: windowModel.isAnimatedImage || (windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3DImmersive)
                ) {
                    show3DPopover = false
                    Task {
                        if windowModel.desiredViewingMode == .spatial3D {
                            await windowModel.switchToViewingMode(.mono)
                        } else {
                            await windowModel.switchToViewingMode(.spatial3D)
                        }
                    }
                }

                Divider()

                popoverMenuButton(
                    title: "Immersive 3D",
                    icon: "inset.filled.pano",
                    isChecked: windowModel.desiredViewingMode == .spatial3DImmersive,
                    isDisabled: windowModel.isAnimatedImage || (windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3D)
                ) {
                    show3DPopover = false
                    Task {
                        if windowModel.desiredViewingMode == .spatial3DImmersive {
                            await windowModel.switchToViewingMode(.mono)
                        } else {
                            await windowModel.switchToViewingMode(.spatial3DImmersive)
                        }
                    }
                }

                Divider()

                popoverMenuButton(
                    title: "Diorama",
                    icon: "spatial.capture.on.hexagon",
                    isChecked: windowModel.isDioramaMode,
                    isDisabled: windowModel.isAnimatedImage || windowModel.isRealityKitDisplay || windowModel.isProcessingDiorama
                ) {
                    show3DPopover = false
                    Task {
                        await windowModel.toggleDiorama()
                    }
                }

                if isAnyAlternateModeActive {
                    Divider()

                    popoverMenuButton(
                        title: "2D",
                        icon: "view.2d",
                        isChecked: false
                    ) {
                        show3DPopover = false
                        Task {
                            if windowModel.isDioramaMode {
                                await windowModel.setDioramaMode(false)
                            }
                            if windowModel.desiredViewingMode != .mono {
                                await windowModel.switchToViewingMode(.mono)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var is3DModeActive: Bool {
        windowModel.desiredViewingMode == .spatial3D || windowModel.desiredViewingMode == .spatial3DImmersive
    }

    private var isAnyAlternateModeActive: Bool {
        is3DModeActive || windowModel.isDioramaMode
    }

    private var threeDMenuIcon: String {
        if windowModel.isDioramaMode { return "spatial.capture.on.hexagon" }
        switch windowModel.desiredViewingMode {
        case .spatial3D: return "spatial.capture.fill"
        case .spatial3DImmersive: return "inset.filled.pano"
        default: return "view.3d"
        }
    }

    // MARK: - Resolution Menu

    @State private var showResolutionPopover = false

    private var resolutionMenu: some View {
        let is3D = windowModel.is3DMode
        let activeOverride = is3D ? windowModel.spatial3DResolutionOverride : windowModel.resolutionOverride
        let displayResolution = is3D ? windowModel.currentSpatial3DSourceDimension : windowModel.currentDisplayResolution
        let helpPrefix = is3D ? "3D Source Resolution" : "Image Resolution"

        return Button {
            showResolutionPopover.toggle()
        } label: {
            Text("\(displayResolution)px")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(activeOverride != nil ? .accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help(activeOverride != nil ? "\(helpPrefix) Override: \(resolutionOverrideLabel)" : helpPrefix)
        .onChange(of: showResolutionPopover) { _, isOpen in
            updateOrnamentMenuCount(opened: isOpen)
        }
        .popover(isPresented: $showResolutionPopover) {
            VStack(spacing: 4) {
                popoverMenuButton(
                    title: "Auto",
                    isChecked: activeOverride == nil
                ) {
                    showResolutionPopover = false
                    Task {
                        if is3D {
                            await windowModel.applySpatial3DResolutionOverride(nil)
                        } else {
                            await windowModel.applyResolutionOverride(nil)
                        }
                    }
                }

                Divider()

                ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                    popoverMenuButton(
                        title: option.label,
                        isChecked: activeOverride == option.value
                    ) {
                        showResolutionPopover = false
                        Task {
                            if is3D {
                                await windowModel.applySpatial3DResolutionOverride(option.value)
                            } else {
                                await windowModel.applyResolutionOverride(option.value)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Label for the current resolution override setting
    private var resolutionOverrideLabel: String {
        let override = windowModel.is3DMode ? windowModel.spatial3DResolutionOverride : windowModel.resolutionOverride
        guard let override else { return "Auto" }
        return AppModel.maxImageResolutionOptions.first { $0.value == override }?.label ?? "\(override)px"
    }

    // MARK: - Info Button (Rating & Metadata)

    private var infoButton: some View {
        Button {
            windowModel.showMediaInfoPopover.toggle()
        } label: {
            Image(systemName: windowModel.image.rating100 != nil ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .foregroundColor(windowModel.image.rating100 != nil ? .yellow : nil)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Info")
        .sheet(isPresented: Bindable(windowModel).showMediaInfoPopover) {
            if let stashId = windowModel.image.stashId {
                MediaDetailSheet(
                    mediaType: .image(stashId: stashId),
                    onDelete: {
                        // Remove from gallery and navigate away
                        let appModel = windowModel.appModel
                        if let idx = appModel.galleryImages.firstIndex(where: { $0.stashId == stashId }) {
                            appModel.galleryImages.remove(at: idx)
                        }
                    },
                    onSaved: { newRating in
                        windowModel.image.rating100 = newRating
                        if let idx = windowModel.galleryImages.firstIndex(where: { $0.stashId == stashId }) {
                            windowModel.galleryImages[idx].rating100 = newRating
                        }
                    }
                )
            }
        }
    }

    // MARK: - Adjustments Button (image enhancements: sliders, auto-enhance, background removal, flip)

    private var adjustmentsButton: some View {
        Button {
            windowModel.showAdjustmentsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .padding(6)
                .background(adjustmentsHighlighted ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .help("Adjustments")
        .popover(isPresented: Bindable(windowModel).showAdjustmentsPopover) {
            VisualAdjustmentsPopover(
                currentAdjustments: Binding(
                    get: { windowModel.currentAdjustments },
                    set: { windowModel.currentAdjustments = $0 }
                ),
                globalAdjustments: Binding(
                    get: { windowModel.appModel.globalVisualAdjustments },
                    set: {
                        windowModel.appModel.globalVisualAdjustments = $0
                        if !windowModel.currentAdjustments.isModified {
                            windowModel.reloadImagePresentationWithAdjustments()
                        }
                    }
                ),
                showAutoEnhance: !windowModel.isAnimatedImage,
                // RealityKit's IPC doesn't honor compositing-time
                // sharpen, so hide the per-image slider while a 3D
                // image is on screen (animated images don't use the
                // sharpen shader path either).
                showSharpen: !windowModel.is3DMode && !windowModel.isAnimatedImage,
                isProcessingAutoEnhance: windowModel.isProcessingAutoEnhance,
                onToggleAutoEnhance: {
                    Task {
                        await windowModel.toggleAutoEnhance()
                    }
                },
                onCurrentAdjustmentsChanged: { adjustments in
                    Task {
                        await windowModel.trackAdjustments()
                    }
                    windowModel.reloadImagePresentationWithAdjustments()
                },
                showBackgroundRemoval: !windowModel.isRealityKitDisplay,
                backgroundRemovalState: windowModel.backgroundRemovalState,
                onToggleBackgroundRemoval: {
                    Task {
                        await windowModel.toggleBackgroundRemoval()
                    }
                },
                showFlip: !windowModel.isRealityKitDisplay && !windowModel.is3DMode,
                isImageFlipped: windowModel.isImageFlipped,
                onToggleFlip: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        windowModel.toggleFlip()
                    }
                }
            )
        }
    }

    /// Increment / decrement the open-menu counter on `windowModel`. Clamped
    /// at zero so a missed event can't drive the count negative.
    private func updateOrnamentMenuCount(opened: Bool) {
        if opened {
            windowModel.openOrnamentMenuCount += 1
            windowModel.cancelAutoHideTimer()
        } else {
            windowModel.openOrnamentMenuCount = max(0, windowModel.openOrnamentMenuCount - 1)
            if windowModel.openOrnamentMenuCount == 0 {
                windowModel.startAutoHideTimer()
            }
        }
    }

    /// Whether the Adjustments button should show a highlight (adjustments modified or image flipped)
    private var adjustmentsHighlighted: Bool {
        windowModel.effectiveAdjustments.isModified || windowModel.isImageFlipped
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task {
                await windowModel.shareImage()
            }
        } label: {
            Group {
                if windowModel.isPreparingShare {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isPreparingShare || windowModel.isLoadingDetailImage)
        .help("Share")
        .sheet(isPresented: Binding(
            get: { windowModel.shareFileURL != nil },
            set: { if !$0 { windowModel.shareFileURL = nil } }
        )) {
            windowModel.startAutoHideTimer()
        } content: {
            if let url = windowModel.shareFileURL {
                ActivityViewController(
                    activityItems: [url],
                    isPresented: Binding(
                        get: { windowModel.shareFileURL != nil },
                        set: { if !$0 { windowModel.shareFileURL = nil } }
                    )
                )
            }
        }
    }

    // MARK: - Popover Menu Button Helper

    /// Reusable button styled to match native visionOS menu item sizing.
    private func popoverMenuButton(
        title: String,
        icon: String? = nil,
        isChecked: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 24)
                }
                Text(title)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
    }
}
