/*
 Spatial Stash - Photo Ornament View

 Unified ornament for all picture viewer windows.
 Controls are configured via PhotoViewerContext to show/hide
 navigation, slideshow, rating, and context-specific buttons.
 */

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
            Task {
                await windowModel.previousSlideshowImage()
            }
        } label: {
            Image(systemName: "backward.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(!windowModel.hasPreviousSlideshowImage || windowModel.isLoadingDetailImage)

        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
            Text("Slideshow")
        }
        .font(.title3)
        .foregroundColor(.secondary)

        Button {
            Task {
                await windowModel.nextSlideshowImage()
            }
        } label: {
            Image(systemName: "forward.fill")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)

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
                if windowModel.spatial3DImageState == .notGenerated {
                    await windowModel.generateSpatial3DImage()
                } else {
                    await windowModel.deactivate3DMode()
                }
            }
        } label: {
            Group {
                if windowModel.spatial3DImageState == .generating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: windowModel.spatial3DImageState == .generated ? "view.3d" : "wand.and.stars")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isAnimatedGIF)
        .help(windowModel.spatial3DImageState == .notGenerated ? "Generate 3D" :
              windowModel.spatial3DImageState == .generating ? "Cancel 3D" : "Exit 3D")
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
