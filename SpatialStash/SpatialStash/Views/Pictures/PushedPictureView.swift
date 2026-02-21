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

    /// Tracks the viewer window's current size (updated live via GeometryReader)
    @State private var viewerWindowSize: CGSize?

    // MARK: - Swipe Gesture State

    /// Horizontal drag offset during swipe gesture
    @State private var dragOffset: CGFloat = 0

    /// Whether a swipe transition animation is in progress
    @State private var isSwipeTransitioning: Bool = false

    /// The width of the view for swipe threshold calculations
    @State private var containerWidth: CGFloat = 0

    /// Suppresses window resize during swipe transitions
    @State private var suppressWindowResize: Bool = false

    /// Minimum drag fraction of container width to trigger swipe
    private let swipeThresholdFraction: CGFloat = 0.15

    /// The bounds used to fit images into — starts as main window size, then tracks viewer size
    private var currentBounds: CGSize {
        viewerWindowSize ?? appModel.mainWindowSize
    }

    var body: some View {
        ZStack {
            imageContent
                .offset(x: dragOffset)

            // Loading overlay (stays in place, not offset with swipe)
            if appModel.isLoadingDetailImage && !isSwipeTransitioning {
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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewerWindowSize = geo.size
                        containerWidth = geo.size.width
                    }
                    .onChange(of: geo.size) { _, newSize in
                        viewerWindowSize = newSize
                        containerWidth = newSize.width
                    }
            }
        )
        .ornament(
            visibility: appModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                PushedPictureOrnament(imageCount: appModel.galleryImages.count)
            }
        )
        .onAppear {
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

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        if appModel.isAnimatedGIF, let gifData = appModel.currentImageData {
            // Display animated GIF without RealityKit (no 3D conversion possible)
            AnimatedGIFDetailView(imageData: gifData)
                .aspectRatio(appModel.imageAspectRatio, contentMode: .fit)
                .contentShape(.rect)
                .onTapGesture {
                    appModel.toggleUIVisibility()
                }
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onChanged { value in
                            handleDragChanged(translation: value.translation.width)
                        }
                        .onEnded { value in
                            handleDragEnded(
                                translation: value.translation.width,
                                predictedEnd: value.predictedEndTranslation.width
                            )
                        }
                )
                .onAppear {
                    resizeGIFWindowToFit(appModel.imageAspectRatio, within: appModel.mainWindowSize)
                }
                .onChange(of: appModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeGIFWindowToFit(appModel.imageAspectRatio, within: currentBounds)
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
                    resizeWindowToFit(appModel.imageAspectRatio, within: appModel.mainWindowSize)
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
                    DragGesture(minimumDistance: 30)
                        .targetedToAnyEntity()
                        .onChanged { value in
                            handleDragChanged(translation: value.translation.width)
                        }
                        .onEnded { value in
                            handleDragEnded(
                                translation: value.translation.width,
                                predictedEnd: value.predictedEndTranslation.width
                            )
                        }
                )
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
                    guard !suppressWindowResize else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: appModel.imageURL) {
                    // Skip if the image was loaded from preloaded data (not in loading state)
                    guard appModel.isLoadingDetailImage else { return }
                    Task {
                        await appModel.createImagePresentationComponent()
                        // Restore cached 2D/3D state for the new image (skip during slideshow)
                        if !appModel.isSlideshowActive {
                            await appModel.autoGenerateSpatial3DIfNeeded()
                        }
                    }
                }
                .onChange(of: appModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(appModel.imageAspectRatio, within: currentBounds)
                    }
                }
            }
            .aspectRatio(appModel.imageAspectRatio, contentMode: .fit)
        }
    }

    // MARK: - Swipe Gesture Handling

    private func handleDragChanged(translation: CGFloat) {
        guard !isSwipeTransitioning && !appModel.isLoadingDetailImage && !appModel.isSlideshowActive else { return }
        dragOffset = translation
    }

    private func handleDragEnded(translation: CGFloat, predictedEnd: CGFloat) {
        guard !isSwipeTransitioning && !appModel.isLoadingDetailImage && !appModel.isSlideshowActive else {
            withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
            return
        }

        let threshold = max(containerWidth * swipeThresholdFraction, 50)
        let shouldNavigateNext = (translation < -threshold || predictedEnd < -threshold * 2) && appModel.hasNextImage
        let shouldNavigatePrevious = (translation > threshold || predictedEnd > threshold * 2) && appModel.hasPreviousImage

        if shouldNavigateNext {
            performSwipeTransition(direction: .next)
        } else if shouldNavigatePrevious {
            performSwipeTransition(direction: .previous)
        } else {
            // Snap back to center
            withAnimation(.easeOut(duration: 0.25)) {
                dragOffset = 0
            }
        }
    }

    private enum SwipeDirection {
        case next
        case previous
    }

    private func performSwipeTransition(direction: SwipeDirection) {
        isSwipeTransitioning = true
        suppressWindowResize = true
        let offScreenOffset: CGFloat = direction == .next ? -containerWidth : containerWidth

        // Phase 1: Animate current image off-screen
        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = offScreenOffset
        }

        // Phase 2: Switch image and position new image on opposite side
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if direction == .next {
                appModel.nextImage()
            } else {
                appModel.previousImage()
            }

            // Position new image on opposite side (no animation)
            dragOffset = -offScreenOffset

            // Phase 3: Animate new image to center
            withAnimation(.easeOut(duration: 0.25)) {
                dragOffset = 0
            }

            // Phase 4: Clear transition state and resize window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
                isSwipeTransitioning = false
                suppressWindowResize = false
                if appModel.isAnimatedGIF {
                    resizeGIFWindowToFit(appModel.imageAspectRatio, within: currentBounds)
                } else {
                    resizeWindowToFit(appModel.imageAspectRatio, within: currentBounds)
                }
            }
        }
    }

    // MARK: - Window Management

    /// Resize window to fit image aspect ratio within given bounds
    private func resizeWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize) {
        guard let windowScene = resolvedWindowScene else { return }

        let boundsAR = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAR {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size))
        }
    }

    /// Resize GIF window to fit image aspect ratio within given bounds (with uniform restrictions)
    private func resizeGIFWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize) {
        guard let windowScene = resolvedWindowScene else { return }

        let boundsAR = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAR {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }

    private func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
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
    @State private var showMediaInfo = false
    @State private var isUpdatingMediaInfo = false
    @State private var pendingPopOutImage: GalleryImage? = nil

    var body: some View {
        HStack(spacing: 16) {
            // Back to Gallery button - dismisses this pushed window
            Button {
                if appModel.isSlideshowActive {
                    appModel.stopSlideshow()
                }
                dismissWindow()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Pictures")

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
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Stop Slideshow")
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
                    Image(systemName: "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isLoadingDetailImage)
                .help("Slideshow")

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
                    Group {
                        if appModel.spatial3DImageState == .generating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: appModel.spatial3DImageState == .generated ? "view.3d" : "wand.and.stars")
                        }
                    }
                    .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.spatial3DImageState == .generating || appModel.isAnimatedGIF)
                .help(appModel.spatial3DImageState == .notGenerated ? "Generate 3D" :
                      appModel.spatial3DImageState == .generating ? "Generating..." : "Toggle 3D")

                // Star rating / O counter popover button
                if appModel.selectedImage?.stashId != nil {
                    Divider()
                        .frame(height: 24)

                    Button {
                        showMediaInfo.toggle()
                    } label: {
                        Image(systemName: appModel.selectedImage?.rating100 != nil ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(appModel.selectedImage?.rating100 != nil ? .yellow : nil)
                    }
                    .buttonStyle(.borderless)
                    .disabled(appModel.isLoadingDetailImage)
                    .help("Rating & O Count")
                    .popover(isPresented: $showMediaInfo) {
                        MediaInfoPopover(
                            currentRating100: appModel.selectedImage?.rating100,
                            oCounter: appModel.selectedImage?.oCounter ?? 0,
                            isUpdating: isUpdatingMediaInfo,
                            onRate: { newRating in
                                guard let stashId = appModel.selectedImage?.stashId else { return }
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.updateImageRating(stashId: stashId, rating100: newRating)
                                    isUpdatingMediaInfo = false
                                }
                            },
                            onIncrementO: {
                                guard let stashId = appModel.selectedImage?.stashId else { return }
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.incrementImageOCounter(stashId: stashId)
                                    isUpdatingMediaInfo = false
                                }
                            },
                            onDecrementO: {
                                guard let stashId = appModel.selectedImage?.stashId else { return }
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.decrementImageOCounter(stashId: stashId)
                                    isUpdatingMediaInfo = false
                                }
                            }
                        )
                    }
                }

                Divider()
                    .frame(height: 24)

                // Pop-out button - opens picture in separate window
                Button {
                    if let image = appModel.selectedImage {
                        if appModel.memoryBudgetExceeded {
                            pendingPopOutImage = image
                            appModel.showMemoryWarningAlert = true
                        } else {
                            openWindow(id: "photo-detail", value: image)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.isLoadingDetailImage)
                .help("Pop Out")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .alert(
            "Memory Warning",
            isPresented: Bindable(appModel).showMemoryWarningAlert
        ) {
            Button("Open Anyway") {
                if let image = pendingPopOutImage {
                    openWindow(id: "photo-detail", value: image)
                    pendingPopOutImage = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPopOutImage = nil
            }
        } message: {
            Text("Opening another window may cause the app to run out of memory. You have \(appModel.openPhotoWindowCount) windows open.")
        }
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
