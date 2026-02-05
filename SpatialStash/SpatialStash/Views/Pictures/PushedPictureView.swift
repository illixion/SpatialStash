/*
 Spatial Stash - Pushed Picture View

 Picture viewer that is pushed from the gallery grid using pushWindow.
 Dismissing this view returns to the gallery with preserved state.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct PushedPictureView: View {
    let image: GalleryImage
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.dismissWindow) private var dismissWindow

    /// Input plane entity for tap gesture hit-testing
    @State private var inputPlaneEntity: Entity = Entity()

    var body: some View {
        ZStack {
            if appModel.isAnimatedGIF, let gifData = appModel.currentImageData {
                // Display animated GIF without RealityKit (no 3D conversion possible)
                AnimatedGIFDetailView(imageData: gifData)
                    .aspectRatio(appModel.imageAspectRatio, contentMode: .fit)
                    .contentShape(.rect)
                    .onTapGesture {
                        appModel.toggleUIVisibility()
                    }
                    .onAppear {
                        setupWindowForGIF()
                    }
                    .onChange(of: appModel.imageAspectRatio) { _, newAspectRatio in
                        resizeWindowForGIF(newAspectRatio)
                    }
                    .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
                        if wasLoading && !isLoading {
                            resizeWindowForGIF(appModel.imageAspectRatio)
                        }
                    }
            } else {
                // Display static image with RealityKit for potential 3D conversion
                GeometryReader3D { geometry in
                    RealityView { content in
                        await appModel.createImagePresentationComponent()
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        content.add(appModel.contentEntity)
                        ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if inputPlaneEntity.parent == nil {
                            content.add(inputPlaneEntity)
                        }
                        resizeWindowToAspectRatio(appModel.imageAspectRatio)
                        await appModel.autoGenerateSpatial3DIfNeeded()
                    } update: { content in
                        guard let presentationScreenSize = appModel
                            .contentEntity
                            .observable
                            .components[ImagePresentationComponent.self]?
                            .presentationScreenSize, presentationScreenSize != .zero else {
                            return
                        }
                        let originalPosition = appModel.contentEntity.position(relativeTo: nil)
                        appModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, 0.0), relativeTo: nil)
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if inputPlaneEntity.parent == nil {
                            content.add(inputPlaneEntity)
                        }
                    }
                    .gesture(
                        TapGesture()
                            .targetedToAnyEntity()
                            .onEnded { _ in
                                appModel.toggleUIVisibility()
                            }
                    )
                    .onAppear {
                        guard let windowScene = resolvedWindowScene else {
                            AppLogger.views.warning("Unable to get the window scene. Unable to set the resizing restrictions.")
                            return
                        }
                        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                    }
                    .onChange(of: appModel.imageAspectRatio) { _, newAspectRatio in
                        resizeWindowToAspectRatio(newAspectRatio)
                    }
                    .onChange(of: appModel.imageURL) {
                        Task {
                            await appModel.createImagePresentationComponent()
                            // Restore cached 2D/3D state for the new image
                            await appModel.autoGenerateSpatial3DIfNeeded()
                        }
                    }
                    .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
                        if wasLoading && !isLoading {
                            resizeWindowToAspectRatio(appModel.imageAspectRatio)
                        }
                    }
                }
                .aspectRatio(appModel.imageAspectRatio, contentMode: .fit)
            }

            // Loading overlay
            if appModel.isLoadingDetailImage {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Loading image...")
                        .font(.title3)
                        .foregroundColor(.white)
                }
            }
        }
        .ornament(
            visibility: appModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                PushedPictureOrnament(imageCount: appModel.galleryImages.count)
            }
        )
        .onAppear {
            // Initialize AppModel state for this image
            appModel.selectImageForDetail(image)
            appModel.startAutoHideTimer()
        }
        .onDisappear {
            appModel.cancelAutoHideTimer()
            appModel.dismissDetailView()
            resetWindowRestrictions()
        }
        .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                appModel.isUIHidden = false
                appModel.startAutoHideTimer()
            }
        }
        .onChange(of: appModel.selectedImage?.id) {
            appModel.isUIHidden = false
            appModel.startAutoHideTimer()
        }
    }

    // MARK: - Window Management

    private func setupWindowForGIF() {
        resizeWindowForGIF(appModel.imageAspectRatio)
    }

    private func resizeWindowForGIF(_ aspectRatio: CGFloat) {
        guard let windowScene = resolvedWindowScene else { return }

        let windowSceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        let currentAspectRatio = windowSceneSize.width / windowSceneSize.height
        if abs(currentAspectRatio - aspectRatio) < 0.01 {
            windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
            return
        }

        let width = aspectRatio * windowSceneSize.height
        let size = CGSize(width: width, height: UIProposedSceneSizeNoPreference)

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }

    private func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    private func resizeWindowToAspectRatio(_ aspectRatio: CGFloat) {
        guard let windowScene = resolvedWindowScene else {
            AppLogger.views.warning("Unable to get the window scene. Resizing is not possible.")
            return
        }

        let windowSceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        let width = aspectRatio * windowSceneSize.height
        let size = CGSize(width: width, height: UIProposedSceneSizeNoPreference)

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size))
        }
    }

    func scaleImagePresentationToFit(in boundsInMeters: BoundingBox) {
        guard let imagePresentationComponent = appModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }

        let presentationScreenSize = imagePresentationComponent.presentationScreenSize
        let scale = min(
            boundsInMeters.extents.x / presentationScreenSize.x,
            boundsInMeters.extents.y / presentationScreenSize.y
        )

        appModel.contentEntity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    // MARK: - Input Plane for Tap Gestures

    private func ensureInputPlaneReady() {
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

    private func updateInputPlane(in boundsInMeters: BoundingBox) {
        let scale = SIMD3<Float>(boundsInMeters.extents.x, boundsInMeters.extents.y, 1.0)
        inputPlaneEntity.scale = scale
        let center = boundsInMeters.center
        inputPlaneEntity.setPosition(
            SIMD3<Float>(center.x, center.y, 0.01),
            relativeTo: nil
        )
    }
}

// MARK: - Pushed Picture Ornament

struct PushedPictureOrnament: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    let imageCount: Int

    var body: some View {
        HStack(spacing: 16) {
            // Back to Gallery button - dismisses this pushed window
            Button {
                if appModel.isSlideshowActive {
                    appModel.stopSlideshow()
                }
                dismissWindow()
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

    private func toggleSpatial3DView() {
        guard var imagePresentationComponent = appModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }

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
