/*
 Spatial Stash - Photo Window View

 Standalone window view for displaying individual photos.
 Each photo opens in its own window with independent state.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct PhotoWindowView: View {
    @State private var windowModel: PhotoWindowModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    
    init(image: GalleryImage, appModel: AppModel) {
        _windowModel = State(initialValue: PhotoWindowModel(image: image, appModel: appModel))
    }
    
    var body: some View {
        ZStack {
            if windowModel.isAnimatedGIF, let gifData = windowModel.currentImageData {
                // Display animated GIF without RealityKit (no 3D conversion possible)
                AnimatedGIFDetailView(imageData: gifData)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .onAppear {
                    setupWindowForGIF()
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    resizeWindowForGIF(newAspectRatio)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    // When loading finishes, ensure window is resized to match the new image
                    if wasLoading && !isLoading {
                        resizeWindowForGIF(windowModel.imageAspectRatio)
                    }
                }
            } else {
                // Display static image with RealityKit for potential 3D conversion
                GeometryReader3D { geometry in
                    RealityView { content in
                        await windowModel.createImagePresentationComponent()
                        // Scale the entity to fit in the bounds.
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        content.add(windowModel.contentEntity)
                        windowModel.ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if windowModel.inputPlaneEntity.parent == nil {
                            content.add(windowModel.inputPlaneEntity)
                        }
                        // Resize window to match initial aspect ratio
                        resizeWindowToAspectRatio(windowModel.imageAspectRatio)
                        // Auto-generate spatial 3D after entity is added to scene
                        await windowModel.autoGenerateSpatial3DIfNeeded()
                    } update: { content in
                        guard let presentationScreenSize = windowModel
                            .contentEntity
                            .observable
                            .components[ImagePresentationComponent.self]?
                            .presentationScreenSize, presentationScreenSize != .zero else {
                                return
                        }
                        // Position the entity at the back of the window.
                        let originalPosition = windowModel.contentEntity.position(relativeTo: nil)
                        windowModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, 0.0), relativeTo: nil)
                        // Scale the entity to fit in the bounds.
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        windowModel.ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if windowModel.inputPlaneEntity.parent == nil {
                            content.add(windowModel.inputPlaneEntity)
                        }
                    }
                    .onAppear() {
                        guard let windowScene = resolvedWindowScene else {
                            AppLogger.views.warning("Unable to get the window scene. Unable to set the resizing restrictions.")
                            return
                        }
                        // Ensure that the scene resizes uniformly on X and Y axes.
                        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                    }
                    .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                        resizeWindowToAspectRatio(newAspectRatio)
                    }
                    .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                        // When loading finishes, ensure window is resized to match the new image
                        if wasLoading && !isLoading {
                            resizeWindowToAspectRatio(windowModel.imageAspectRatio)
                        }
                    }
                    .gesture(
                        TapGesture()
                            .targetedToAnyEntity()
                            .onEnded { _ in
                                windowModel.toggleUIVisibility()
                            }
                    )
                }
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            }
            
        }
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                PhotoWindowOrnament(windowModel: windowModel)
            }
        )
        .onAppear {
            windowModel.startAutoHideTimer()
        }
        .onDisappear {
            windowModel.cancelAutoHideTimer()
            resetWindowRestrictions()
        }
        .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
            // Start auto-hide timer when loading finishes
            if wasLoading && !isLoading {
                windowModel.isUIHidden = false
                windowModel.startAutoHideTimer()
            }
        }
    }
    
    private func setupWindowForGIF() {
        resizeWindowForGIF(windowModel.imageAspectRatio)
    }

    /// Resize window for GIF, always including uniform restriction to maintain aspect ratio
    private func resizeWindowForGIF(_ aspectRatio: CGFloat) {
        guard let windowScene = resolvedWindowScene else { return }

        let windowSceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size

        // Skip resizing if already at the correct aspect ratio
        let currentAspectRatio = windowSceneSize.width / windowSceneSize.height
        if abs(currentAspectRatio - aspectRatio) < 0.01 {
            // Still ensure uniform restriction is set even if size is correct
            windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
            return
        }

        let width = aspectRatio * windowSceneSize.height
        let size = CGSize(width: width, height: UIProposedSceneSizeNoPreference)

        UIView.performWithoutAnimation {
            // Combine size and uniform restriction in single call to prevent override
            windowScene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }
    
    private func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }
    
    /// Resize the window to match the given aspect ratio
    private func resizeWindowToAspectRatio(_ aspectRatio: CGFloat) {
        guard let windowScene = resolvedWindowScene else {
            AppLogger.views.warning("Unable to get the window scene. Resizing is not possible.")
            return
        }

        let windowSceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size

        // Skip resizing if already at the correct aspect ratio (allows state restoration to persist)
        let currentAspectRatio = windowSceneSize.width / windowSceneSize.height
        if abs(currentAspectRatio - aspectRatio) < 0.01 {
            return
        }

        //  width / height = aspect ratio
        // Change ONLY the width to match the aspect ratio.
        let width = aspectRatio * windowSceneSize.height

        // Keep the height the same.
        let size = CGSize(width: width, height: UIProposedSceneSizeNoPreference)

        UIView.performWithoutAnimation {
            // Update the scene size.
            windowScene.requestGeometryUpdate(.Vision(size: size))
        }
    }
    
    /// Fit the image presentation inside a bounding box by scaling the content entity.
    func scaleImagePresentationToFit(in boundsInMeters: BoundingBox) {
        guard let imagePresentationComponent = windowModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }
        
        let presentationScreenSize = imagePresentationComponent.presentationScreenSize
        let scale = min(
            boundsInMeters.extents.x / presentationScreenSize.x,
            boundsInMeters.extents.y / presentationScreenSize.y
        )
        
        windowModel.contentEntity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    /// Match the input plane to the current window bounds for hit-testing.
    func updateInputPlane(in boundsInMeters: BoundingBox) {
        let scale = SIMD3<Float>(boundsInMeters.extents.x, boundsInMeters.extents.y, 1.0)
        windowModel.inputPlaneEntity.scale = scale
        let center = boundsInMeters.center
        windowModel.inputPlaneEntity.setPosition(
            SIMD3<Float>(center.x, center.y, 0.01),
            relativeTo: nil
        )
    }

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

/// Ornament for photo window controls
struct PhotoWindowOrnament: View {
    @Bindable var windowModel: PhotoWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 16) {
            // Show main gallery window button
            Button {
                if windowModel.isSlideshowActive {
                    windowModel.stopSlideshow()
                }
                openWindow(id: "main")
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Show Gallery")

            Divider()
                .frame(height: 24)

            if windowModel.isSlideshowActive {
                // Slideshow controls
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

                // Slideshow indicator
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

                // Stop slideshow button
                Button {
                    windowModel.stopSlideshow()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Stop Slideshow")
            } else {
                // Gallery navigation controls
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

                // Image counter
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

                Divider()
                    .frame(height: 24)

                // Start slideshow button
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

                Divider()
                    .frame(height: 24)

                // Generate/Toggle 3D button
                Button {
                    Task {
                        if windowModel.spatial3DImageState == .notGenerated {
                            await windowModel.generateSpatial3DImage()
                        } else {
                            windowModel.toggleSpatial3DView()
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
                .disabled(windowModel.spatial3DImageState == .generating || windowModel.isAnimatedGIF)
                .help(windowModel.spatial3DImageState == .notGenerated ? "Generate 3D" :
                      windowModel.spatial3DImageState == .generating ? "Generating..." : "Toggle 3D")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}
