/*
 Spatial Stash - Picture Ornaments View

 Controls for the picture viewer including navigation, 3D toggle, slideshow, and pop-out.
 */

import RealityKit
import SwiftUI

struct PictureOrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    let imageCount: Int

    var body: some View {
        HStack(spacing: 16) {
            // Back to Gallery button
            Button {
                if appModel.isSlideshowActive {
                    appModel.stopSlideshow()
                }
                appModel.dismissDetailView()
            } label: {
                if appModel.isSlideshowActive {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("Pictures")
                    }
                    .font(.title3)
                }
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 24)

            if appModel.isSlideshowActive {
                // Slideshow controls
                Button {
                    appModel.previousSlideshowImage()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!appModel.hasPreviousSlideshowImage || appModel.isLoadingDetailImage)

                // Slideshow indicator
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text("Slideshow")
                }
                .font(.title3)
                .foregroundColor(.secondary)

                Button {
                    Task {
                        await appModel.nextSlideshowImage()
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isLoadingDetailImage)

                Divider()
                    .frame(height: 24)

                // Stop slideshow button
                Button {
                    appModel.stopSlideshow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                    .font(.title3)
                }
                .buttonStyle(.borderless)
            } else {
                // Gallery navigation controls
                Button {
                    appModel.previousImage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!appModel.hasPreviousImage || appModel.isLoadingDetailImage)

                // Image counter
                if appModel.isLoadingDetailImage {
                    ProgressView()
                        .frame(minWidth: 60)
                } else {
                    Text("\(appModel.currentImagePosition) / \(imageCount)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 60)
                }

                Button {
                    appModel.nextImage()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!appModel.hasNextImage || appModel.isLoadingDetailImage)

                Divider()
                    .frame(height: 24)

                // Start slideshow button
                Button {
                    Task {
                        await appModel.startSlideshow()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Slideshow")
                    }
                    .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isLoadingDetailImage)

                Divider()
                    .frame(height: 24)

                // Generate/Toggle 3D button
                Button {
                    Task {
                        if appModel.spatial3DImageState == .notGenerated {
                            try? await appModel.generateSpatial3DImage()
                        } else {
                            toggleSpatial3DView()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if appModel.spatial3DImageState == .generating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: appModel.spatial3DImageState == .generated ? "view.3d" : "wand.and.stars")
                        }
                        Text(appModel.spatial3DImageState == .notGenerated ? "Generate 3D" :
                             appModel.spatial3DImageState == .generating ? "Generating..." : "Toggle 3D")
                    }
                    .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.spatial3DImageState == .generating || appModel.isAnimatedGIF)

                Divider()
                    .frame(height: 24)

                // Pop-out button - opens picture in separate window
                Button {
                    if let image = appModel.selectedImage {
                        openWindow(id: "photo-detail", value: image)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                        Text("Pop Out")
                    }
                    .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isLoadingDetailImage)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    /// Toggle 2D/3D view using AppModel's contentEntity
    private func toggleSpatial3DView() {
        guard var imagePresentationComponent = appModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }

        // Toggle viewing mode
        if imagePresentationComponent.viewingMode == .spatial3D {
            imagePresentationComponent.desiredViewingMode = .mono
            appModel.contentEntity.components.set(imagePresentationComponent)
            if let url = appModel.imageURL {
                Task {
                    await Spatial3DConversionTracker.shared.setLastViewingMode(url: url, mode: .mono)
                }
            }
        } else if appModel.spatial3DImageState == .generated {
            imagePresentationComponent.desiredViewingMode = .spatial3D
            appModel.contentEntity.components.set(imagePresentationComponent)
            if let url = appModel.imageURL {
                Task {
                    await Spatial3DConversionTracker.shared.setLastViewingMode(url: url, mode: .spatial3D)
                }
            }
        }
    }
}
