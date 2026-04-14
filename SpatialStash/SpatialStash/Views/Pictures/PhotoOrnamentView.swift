/*
 Spatial Stash - Photo Ornament View

 Unified ornament for all picture viewer windows.
 Controls are configured via PhotoViewerContext to show/hide
 navigation, slideshow, rating, and context-specific buttons.

 Layout: [Gallery] | [< N/M >] | [Slideshow] | [3D v] | [Info] | [Share] | [... More v] | [Resolution]
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

            moreMenu

            // Resolution indicator (only in lightweight 2D mode with a loaded image)
            if !windowModel.isRealityKitDisplay, !windowModel.isAnimatedImage, windowModel.displayTexture != nil || windowModel.displayImage != nil {
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
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
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
            newConfig.delay = appModel.slideshowDelay
            newConfig.showClock = false
            newConfig.transparentBackground = true
            appModel.gallerySlideshowConfig = newConfig
            config = newConfig
        }
        openWindow(id: "remote-viewer", value: RemoteViewerWindowValue(configId: config.id))
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
            .background(is3DModeActive ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedImage)
        .help("3D")
        .popover(isPresented: $show3DPopover) {
            VStack(spacing: 4) {
                popoverMenuButton(
                    title: "3D",
                    icon: "square.stack.3d.forward.dottedline.fill",
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
                    icon: "square.arrowtriangle.4.outward",
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

                if is3DModeActive {
                    Divider()

                    popoverMenuButton(
                        title: "2D",
                        icon: "view.2d",
                        isChecked: false
                    ) {
                        show3DPopover = false
                        Task {
                            await windowModel.switchToViewingMode(.mono)
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

    private var threeDMenuIcon: String {
        switch windowModel.desiredViewingMode {
        case .spatial3D: return "square.stack.3d.forward.dottedline.fill"
        case .spatial3DImmersive: return "square.arrowtriangle.4.outward"
        default: return "view.3d"
        }
    }

    // MARK: - Resolution Menu

    @State private var showResolutionPopover = false

    private var resolutionMenu: some View {
        Button {
            showResolutionPopover.toggle()
        } label: {
            Text("\(windowModel.currentDisplayResolution)px")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(windowModel.resolutionOverride != nil ? .accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help(windowModel.resolutionOverride != nil ? "Resolution Override: \(resolutionOverrideLabel)" : "Image Resolution")
        .popover(isPresented: $showResolutionPopover) {
            VStack(spacing: 4) {
                popoverMenuButton(
                    title: "Auto",
                    isChecked: windowModel.resolutionOverride == nil
                ) {
                    showResolutionPopover = false
                    Task { await windowModel.applyResolutionOverride(nil) }
                }

                Divider()

                ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                    popoverMenuButton(
                        title: option.label,
                        isChecked: windowModel.resolutionOverride == option.value
                    ) {
                        showResolutionPopover = false
                        Task { await windowModel.applyResolutionOverride(option.value) }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Label for the current resolution override setting
    private var resolutionOverrideLabel: String {
        guard let override = windowModel.resolutionOverride else { return "Auto" }
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
                    }
                )
            }
        }
    }

    // MARK: - More Menu (Adjustments, Flip, extras)

    private var moreMenu: some View {
        Menu {
            // Visual Adjustments (opens popover — use a Button that toggles the popover state)
            Button {
                windowModel.showAdjustmentsPopover.toggle()
            } label: {
                Label("Adjustments", systemImage: "slider.horizontal.3")
            }

            // Flip (only in 2D non-animated mode)
            if !windowModel.isRealityKitDisplay && !windowModel.is3DMode && !windowModel.isAnimatedImage {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        windowModel.toggleFlip()
                    }
                } label: {
                    Label(
                        windowModel.isImageFlipped ? "Unflip" : "Flip",
                        systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                    )
                }
            }

            // Context-specific extra menu items
            extraMenuItems()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .padding(6)
                .background(moreMenuHighlighted ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("More")
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

    /// Whether the More menu button should show a highlight (adjustments modified or image flipped)
    private var moreMenuHighlighted: Bool {
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
