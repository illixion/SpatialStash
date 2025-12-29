/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The view containing the entity with the ImagePresentationComponent.
*/

import RealityKit
import SwiftUI

struct ImagePresentationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate

    var body: some View {
        ZStack {
            GeometryReader3D { geometry in
                RealityView { content in
                    await appModel.createImagePresentationComponent()
                    // Scale the entity to fit in the bounds.
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    content.add(appModel.contentEntity)
                    // Resize window to match initial aspect ratio
                    resizeWindowToAspectRatio(appModel.imageAspectRatio)
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
                }
                .onAppear() {
                    guard let windowScene = sceneDelegate.windowScene else {
                        print("Unable to get the window scene. Unable to set the resizing restrictions.")
                        return
                    }
                    // Ensure that the scene resizes uniformly on X and Y axes.
                    windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                }
                .onDisappear() {
                    guard let windowScene = sceneDelegate.windowScene else {
                        return
                    }
                    // Reset to freeform resizing when leaving detail view
                    windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
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
    }

    /// Resize the window to match the given aspect ratio
    private func resizeWindowToAspectRatio(_ aspectRatio: CGFloat) {
        guard let windowScene = sceneDelegate.windowScene else {
            print("Unable to get the window scene. Resizing is not possible.")
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
}
