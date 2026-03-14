/*
 Spatial Stash - Photo Ornament View

 Unified ornament for all picture viewer windows.
 Controls are configured via PhotoViewerContext to show/hide
 navigation, slideshow, rating, and context-specific buttons.
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

struct PhotoOrnamentView<ExtraButtons: View>: View {
    @Bindable var windowModel: PhotoWindowModel
    let context: PhotoViewerContext
    var onGalleryButtonTap: () -> Void
    @ViewBuilder var extraButtons: () -> ExtraButtons

    @State private var showMediaInfo = false
    @State private var isUpdatingMediaInfo = false

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
                if windowModel.isSlideshowActive {
                    slideshowControls
                } else {
                    navigationControls

                    Divider()
                        .frame(height: 24)

                    slideshowButton

                    Divider()
                        .frame(height: 24)
                }
            }

            threeDButton
            immersive3DButton

            // Background removal only available with lightweight 2D display
            if !windowModel.isRealityKitDisplay {
                backgroundRemovalButton
            }

            // Flip only available with lightweight 2D or GIF display (not RealityKit)
            if !windowModel.isRealityKitDisplay, !windowModel.is3DMode {
                flipButton
            }

            // Resolution indicator (only in lightweight 2D mode with a loaded image)
            if !windowModel.isRealityKitDisplay, !windowModel.isAnimatedGIF, windowModel.displayImage != nil {
                resolutionMenu
            }

            Divider()
                .frame(height: 24)

            shareButton

            // Rating / O counter (when stashId exists and not shared context)
            if context != .shared, windowModel.image.stashId != nil {
                Divider()
                    .frame(height: 24)

                ratingButton
            }

            // Extra buttons (pop-out, save, etc.)
            extraButtons()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Slideshow Controls

    @ViewBuilder
    private var slideshowControls: some View {
        Button {
            windowModel.previousSlideshowImage()
        } label: {
            Image(systemName: "backward.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(!windowModel.hasPreviousSlideshowImage || windowModel.isLoadingDetailImage || windowModel.slideshowTransitionDirection != nil)

        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
            Text("Slideshow")
        }
        .font(.title3)
        .foregroundColor(.secondary)

        Button {
            windowModel.nextSlideshowImage()
        } label: {
            Image(systemName: "forward.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage || windowModel.slideshowTransitionDirection != nil)

        Divider()
            .frame(height: 24)

        Button {
            windowModel.stopSlideshow()
        } label: {
            Image(systemName: "stop.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .help("Stop Slideshow")
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
            Task {
                await windowModel.startSlideshow()
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Slideshow")
    }

    // MARK: - 3D Toggle

    private var threeDButton: some View {
        Button {
            Task {
                if windowModel.desiredViewingMode == .spatial3D {
                    await windowModel.switchToViewingMode(.mono)
                } else {
                    await windowModel.switchToViewingMode(.spatial3D)
                }
            }
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3DImmersive {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "view.3d")
                }
            }
            .font(.title3)
            .padding(6)
            .background(windowModel.desiredViewingMode == .spatial3D ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedGIF || (windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3DImmersive))
        .help("3D")
    }

    private var immersive3DButton: some View {
        Button {
            Task {
                if windowModel.desiredViewingMode == .spatial3DImmersive {
                    await windowModel.switchToViewingMode(.mono)
                } else {
                    await windowModel.switchToViewingMode(.spatial3DImmersive)
                }
            }
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode == .spatial3DImmersive {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "square.arrowtriangle.4.outward")
                }
            }
            .font(.title3)
            .padding(6)
            .background(windowModel.desiredViewingMode == .spatial3DImmersive ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedGIF || (windowModel.spatial3DImageState == .generating && windowModel.desiredViewingMode != .spatial3D))
        .help("Immersive 3D")
    }

    // MARK: - Background Removal Toggle

    private var backgroundRemovalButton: some View {
        Button {
            Task {
                await windowModel.toggleBackgroundRemoval()
            }
        } label: {
            Group {
                if windowModel.backgroundRemovalState == .removing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: windowModel.backgroundRemovalState == .original ? "person.and.background.striped.horizontal" : "person.and.background.dotted")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.is3DMode || windowModel.isAnimatedGIF || (windowModel.isLoadingDetailImage && windowModel.backgroundRemovalState != .removing))
        .help(
            windowModel.backgroundRemovalState == .original ? "Remove Background" :
            windowModel.backgroundRemovalState == .removing ? "Cancel" : "Restore Background"
        )
    }

    // MARK: - Flip Image

    private var flipButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                windowModel.toggleFlip()
            }
        } label: {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.title3)
                .padding(6)
                .background(windowModel.isImageFlipped ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Flip Image")
    }

    // MARK: - Resolution Menu

    private var resolutionMenu: some View {
        Menu {
            // "Auto" option clears the override, reverting to global setting
            Button {
                Task { await windowModel.applyResolutionOverride(nil) }
            } label: {
                HStack {
                    Text("Auto")
                    if windowModel.resolutionOverride == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                Button {
                    Task { await windowModel.applyResolutionOverride(option.value) }
                } label: {
                    HStack {
                        Text(option.label)
                        if windowModel.resolutionOverride == option.value {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text("\(windowModel.currentDisplayResolution)px")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(windowModel.resolutionOverride != nil ? .accentColor : .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help(windowModel.resolutionOverride != nil ? "Resolution Override: \(resolutionOverrideLabel)" : "Image Resolution")
    }

    /// Label for the current resolution override setting
    private var resolutionOverrideLabel: String {
        guard let override = windowModel.resolutionOverride else { return "Auto" }
        return AppModel.maxImageResolutionOptions.first { $0.value == override }?.label ?? "\(override)px"
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

    // MARK: - Rating & O Counter

    private var ratingButton: some View {
        Button {
            showMediaInfo.toggle()
        } label: {
            Image(systemName: windowModel.image.rating100 != nil ? "star.fill" : "star")
                .font(.title3)
                .foregroundColor(windowModel.image.rating100 != nil ? .yellow : nil)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Rating & O Count")
        .popover(isPresented: $showMediaInfo) {
            MediaInfoPopover(
                currentRating100: windowModel.image.rating100,
                oCounter: windowModel.image.oCounter ?? 0,
                isUpdating: isUpdatingMediaInfo,
                onRate: { newRating in
                    guard let stashId = windowModel.image.stashId else { return }
                    isUpdatingMediaInfo = true
                    Task {
                        try? await windowModel.updateImageRating(stashId: stashId, rating100: newRating)
                        isUpdatingMediaInfo = false
                    }
                },
                onIncrementO: {
                    guard let stashId = windowModel.image.stashId else { return }
                    isUpdatingMediaInfo = true
                    Task {
                        try? await windowModel.incrementImageOCounter(stashId: stashId)
                        isUpdatingMediaInfo = false
                    }
                },
                onDecrementO: {
                    guard let stashId = windowModel.image.stashId else { return }
                    isUpdatingMediaInfo = true
                    Task {
                        try? await windowModel.decrementImageOCounter(stashId: stashId)
                        isUpdatingMediaInfo = false
                    }
                }
            )
        }
    }
}
