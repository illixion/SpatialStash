/*
 Spatial Stash - Ornaments View

 Controls for the detail image view including navigation, 2D/3D toggle, and back button.
 */

import os
import RealityKit
import SwiftUI

struct OrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    let imageCount: Int

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                // Back to Gallery button (also stops slideshow)
                Button {
                    if appModel.isSlideshowActive {
                        appModel.stopSlideshow()
                    }
                    appModel.dismissDetailView()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Gallery")
                    }
                }

                Divider()
                    .frame(height: 24)

                if appModel.isSlideshowActive {
                    // Slideshow controls
                    Button {
                        appModel.previousSlideshowImage()
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(!appModel.hasPreviousSlideshowImage || appModel.isLoadingDetailImage)

                    // Slideshow indicator
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("Slideshow")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 80)

                    Button {
                        Task {
                            await appModel.nextSlideshowImage()
                        }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(appModel.isLoadingDetailImage)

                    Divider()
                        .frame(height: 24)

                    // Stop slideshow button
                    Button {
                        appModel.stopSlideshow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                    }
                } else {
                    // Normal navigation controls
                    // Previous image
                    Button {
                        appModel.previousImage()
                    } label: {
                        Image(systemName: "arrow.left.circle")
                    }
                    .disabled(!appModel.hasPreviousImage || appModel.isLoadingDetailImage)

                    // Image counter or loading indicator
                    if appModel.isLoadingDetailImage {
                        ProgressView()
                            .frame(minWidth: 60)
                    } else if appModel.currentImagePosition > 0 {
                        Text("\(appModel.currentImagePosition) / \(imageCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 60)
                    }

                    // Next image
                    Button {
                        appModel.nextImage()
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .disabled(!appModel.hasNextImage || appModel.isLoadingDetailImage)

                    Divider()
                        .frame(height: 24)

                    // Start slideshow button
                    Button {
                        Task {
                            await appModel.startSlideshow()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Slideshow")
                        }
                    }
                    .disabled(appModel.isLoadingDetailImage)
                }

                // 2D/3D Toggle - only show for non-GIF images
                if !appModel.isAnimatedGIF {
                    Divider()
                        .frame(height: 24)

                    Button {
                        guard var ipc = appModel.contentEntity.components[ImagePresentationComponent.self] else {
                            AppLogger.views.warning("Unable to find ImagePresentationComponent.")
                            return
                        }
                        let currentURL = appModel.imageURL
                        switch ipc.viewingMode {
                        case .mono:
                            switch appModel.spatial3DImageState {
                            case .generated:
                                ipc.desiredViewingMode = .spatial3D
                                appModel.contentEntity.components.set(ipc)
                                if let url = currentURL {
                                    Task { await Spatial3DConversionTracker.shared.setLastViewingMode(url: url, mode: .spatial3D) }
                                }
                            case .notGenerated:
                                Task {
                                    do {
                                        try await appModel.generateSpatial3DImage()
                                    } catch {
                                        AppLogger.views.error("Spatial3DImage generation failed: \(error.localizedDescription, privacy: .public)")
                                        appModel.spatial3DImageState = .notGenerated
                                    }
                                }
                            case .generating:
                                AppLogger.views.debug("Spatial 3D Image is still generating...")
                                return
                            }
                        case .spatial3D:
                            ipc.desiredViewingMode = .mono
                            appModel.contentEntity.components.set(ipc)
                            if let url = currentURL {
                                Task { await Spatial3DConversionTracker.shared.setLastViewingMode(url: url, mode: .mono) }
                            }
                        default:
                            AppLogger.views.debug("Unhandled viewing mode: \(String(describing: ipc.viewingMode), privacy: .public)")
                        }
                    } label: {
                        // Show loading state or current viewing mode
                        if appModel.isLoadingDetailImage {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading...")
                            }
                        } else if let viewingMode = appModel.contentEntity.observable.components[ImagePresentationComponent.self]?.viewingMode {
                            switch viewingMode {
                            case .mono:
                                HStack(spacing: 4) {
                                    Image(systemName: "cube")
                                    Text(appModel.spatial3DImageState == .generated ? "Show 3D" : "Convert to 3D")
                                }
                            case .spatial3D:
                                HStack(spacing: 4) {
                                    Image(systemName: "square")
                                    Text("Show 2D")
                                }
                            default:
                                HStack(spacing: 4) {
                                    Image(systemName: "cube")
                                    Text("Convert to 3D")
                                }
                            }
                        } else {
                            // Component not loaded yet - show default state
                            HStack(spacing: 4) {
                                Image(systemName: "cube")
                                Text("Convert to 3D")
                            }
                        }
                    }
                    .disabled(appModel.isLoadingDetailImage)
                } else {
                    // Show GIF indicator instead of 3D button
                    Divider()
                        .frame(height: 24)

                    HStack(spacing: 4) {
                        Image(systemName: "play.circle")
                        Text("Animated GIF")
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .glassBackgroundEffect()
    }
}
