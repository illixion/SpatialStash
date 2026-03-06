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

            // Background removal only available with lightweight 2D display
            if !windowModel.isRealityKitDisplay {
                backgroundRemovalButton
            }

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
        Menu {
            Button {
                Task { await windowModel.switchToViewingMode(.mono) }
            } label: {
                Label("2D", systemImage: "view.2d")
            }

            Button {
                Task { await windowModel.switchToViewingMode(.spatial3D) }
            } label: {
                Label("3D", systemImage: "view.3d")
            }

            Button {
                Task { await windowModel.switchToViewingMode(.spatial3DImmersive) }
            } label: {
                Label("Immersive 3D", systemImage: "square.arrowtriangle.4.outward")
            }
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if windowModel.desiredViewingMode == .spatial3DImmersive {
                    Image(systemName: "square.arrowtriangle.4.outward")
                } else if windowModel.desiredViewingMode == .spatial3D {
                    Image(systemName: "view.3d")
                } else {
                    Image(systemName: "view.2d")
                }
            }
            .font(.title3)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedGIF || windowModel.spatial3DImageState == .generating)
        .help("Display Mode")
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
        .disabled(windowModel.is3DMode || windowModel.isAnimatedGIF || windowModel.isLoadingDetailImage)
        .help(
            windowModel.backgroundRemovalState == .original ? "Remove Background" :
            windowModel.backgroundRemovalState == .removing ? "Cancel" : "Restore Background"
        )
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
