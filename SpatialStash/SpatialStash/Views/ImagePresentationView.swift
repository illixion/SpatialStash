/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The view containing the entity with the ImagePresentationComponent.
Handles both static images (with spatial 3D conversion) and animated GIFs.
*/

import os
import RealityKit
import SwiftUI
import UIKit

struct ImagePresentationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

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
                    // When loading finishes, ensure window is resized to match the new image
                    if wasLoading && !isLoading {
                        resizeWindowForGIF(appModel.imageAspectRatio)
                    }
                }
            } else {
                // Display static image with RealityKit for potential 3D conversion
                GeometryReader3D { geometry in
                    RealityView { content in
                        await appModel.createImagePresentationComponent()
                        // Scale the entity to fit in the bounds.
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        content.add(appModel.contentEntity)
                        ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if inputPlaneEntity.parent == nil {
                            content.add(inputPlaneEntity)
                        }
                        // Resize window to match initial aspect ratio
                        resizeWindowToAspectRatio(appModel.imageAspectRatio)
                        // Auto-generate spatial 3D after entity is added to scene
                        await appModel.autoGenerateSpatial3DIfNeeded()
                    } update: { content in
                        guard let presentationScreenSize = appModel
                            .contentEntity
                            .observable
                            .components[ImagePresentationComponent.self]?
                            .presentationScreenSize, presentationScreenSize != .zero else {
                                return
                        }
                        // Position the entity at the back of the window.
                        let originalPosition = appModel.contentEntity.position(relativeTo: nil)
                        appModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, 0.0), relativeTo: nil)
                        // Scale the entity to fit in the bounds.
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
                    .onAppear() {
                        guard let windowScene = resolvedWindowScene else {
                            AppLogger.views.warning("Unable to get the window scene. Unable to set the resizing restrictions.")
                            return
                        }
                        // Ensure that the scene resizes uniformly on X and Y axes.
                        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                    }
                    .onChange(of: appModel.imageAspectRatio) { _, newAspectRatio in
                        resizeWindowToAspectRatio(newAspectRatio)
                    }
                    .onChange(of: appModel.imageURL) {
                        Task {
                            await appModel.createImagePresentationComponent()
                        }
                    }
                    .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
                        // When loading finishes, ensure window is resized to match the new image
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
        .onAppear {
            appModel.startAutoHideTimer()
        }
        .onDisappear {
            appModel.cancelAutoHideTimer()
            resetWindowRestrictions()
        }
        .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
            // Start auto-hide timer when loading finishes
            if wasLoading && !isLoading {
                appModel.isUIHidden = false
                appModel.startAutoHideTimer()
            }
        }
        .onChange(of: appModel.selectedImage?.id) {
            // Reset UI visibility and timer when image changes
            appModel.isUIHidden = false
            appModel.startAutoHideTimer()
        }
    }

    private func setupWindowForGIF() {
        resizeWindowForGIF(appModel.imageAspectRatio)
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

    /// Ensure the input plane entity has the required components for hit-testing
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

    /// Match the input plane to the current window bounds for hit-testing
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
