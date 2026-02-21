/*
 Spatial Stash - Photo Display View

 Shared image display component used by all picture viewer windows.
 Handles animated GIF, RealityKit 3D, and lightweight 2D display modes
 with optional swipe navigation and automatic window sizing.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct PhotoDisplayView: View {
    @Bindable var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    /// Whether swipe navigation between gallery images is enabled
    let enableSwipeNavigation: Bool

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
            if windowModel.isLoadingDetailImage && !isSwipeTransitioning {
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
                        windowModel.handleWindowResize(newSize)
                    }
            }
        )
        .onAppear {
            // Load initial 2D display image at the default window size
            if !windowModel.isAnimatedGIF && windowModel.displayImage == nil && !windowModel.is3DMode {
                Task {
                    await windowModel.loadDisplayImage(for: appModel.mainWindowSize)
                }
            }
        }
        .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                windowModel.isUIHidden = false
                windowModel.startAutoHideTimer()
            }
        }
        .onChange(of: appModel.useLightweightDisplay) { wasLightweight, isLightweight in
            if !wasLightweight && isLightweight {
                Task {
                    await windowModel.switchToLightweightDisplay()
                }
            }
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        if windowModel.isAnimatedGIF, let gifData = windowModel.currentImageData {
            // Display animated GIF without RealityKit (no 3D conversion possible)
            AnimatedGIFDetailView(imageData: gifData)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .modifier(SwipeGestureModifier(enabled: enableSwipeNavigation, onChanged: handleDragChanged, onEnded: handleDragEnded))
                .onAppear {
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: appModel.mainWindowSize)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    }
                }
        } else if windowModel.is3DMode {
            // Display with RealityKit for 3D spatial conversion (full resolution)
            GeometryReader3D { geometry in
                RealityView { content in
                    await windowModel.createImagePresentationComponent()
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    content.add(windowModel.contentEntity)
                    windowModel.ensureInputPlaneReady()
                    updateInputPlane(in: availableBounds)
                    if windowModel.inputPlaneEntity.parent == nil {
                        content.add(windowModel.inputPlaneEntity)
                    }
                    resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)

                    // Only handle 3D generation when in explicit 3D mode
                    if windowModel.is3DMode {
                        if windowModel.pendingGenerate3D {
                            windowModel.pendingGenerate3D = false
                            await windowModel.generateSpatial3DImage()
                        } else {
                            await windowModel.autoGenerateSpatial3DIfNeeded()
                        }
                    }
                } update: { content in
                    guard let presentationScreenSize = windowModel
                        .contentEntity
                        .observable
                        .components[ImagePresentationComponent.self]?
                        .presentationScreenSize, presentationScreenSize != .zero else {
                            return
                    }
                    let originalPosition = windowModel.contentEntity.position(relativeTo: nil)
                    windowModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, 0.0), relativeTo: nil)
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    windowModel.ensureInputPlaneReady()
                    updateInputPlane(in: availableBounds)
                    if windowModel.inputPlaneEntity.parent == nil {
                        content.add(windowModel.inputPlaneEntity)
                    }
                }
                .modifier(EntitySwipeGestureModifier(enabled: enableSwipeNavigation, onChanged: handleDragChanged, onEnded: handleDragEnded))
                .gesture(
                    TapGesture()
                        .targetedToAnyEntity()
                        .onEnded { _ in
                            windowModel.toggleUIVisibility()
                        }
                )
                .onAppear {
                    guard let windowScene = resolvedWindowScene else {
                        AppLogger.views.warning("Unable to get the window scene. Unable to set the resizing restrictions.")
                        return
                    }
                    windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    }
                }
            }
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
        } else if let uiImage = windowModel.displayImage {
            // Lightweight 2D display with downsampled UIImage (no RealityKit, low memory)
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .modifier(SwipeGestureModifier(enabled: enableSwipeNavigation, onChanged: handleDragChanged, onEnded: handleDragEnded))
                .onAppear {
                    setUniformResizing()
                    resizeWindowToFit(windowModel.imageAspectRatio, within: appModel.mainWindowSize)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    }
                }
        }
    }

    // MARK: - Swipe Gesture Handling

    private func handleDragChanged(translation: CGFloat) {
        guard !isSwipeTransitioning && !windowModel.isLoadingDetailImage && !windowModel.isSlideshowActive else { return }
        dragOffset = translation
    }

    private func handleDragEnded(translation: CGFloat, predictedEnd: CGFloat) {
        guard !isSwipeTransitioning && !windowModel.isLoadingDetailImage && !windowModel.isSlideshowActive else {
            withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
            return
        }

        let threshold = max(containerWidth * swipeThresholdFraction, 50)
        let shouldNavigateNext = (translation < -threshold || predictedEnd < -threshold * 2) && windowModel.hasNextGalleryImage
        let shouldNavigatePrevious = (translation > threshold || predictedEnd > threshold * 2) && windowModel.hasPreviousGalleryImage

        if shouldNavigateNext {
            performSwipeTransition(direction: .next)
        } else if shouldNavigatePrevious {
            performSwipeTransition(direction: .previous)
        } else {
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
            Task {
                if direction == .next {
                    await windowModel.nextGalleryImage()
                } else {
                    await windowModel.previousGalleryImage()
                }
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
                if windowModel.isAnimatedGIF {
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                } else {
                    resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                }
            }
        }
    }

    // MARK: - Window Sizing

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

    private func setUniformResizing() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
    }

    func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    /// Fit the image presentation inside a bounding box by scaling the content entity.
    private func scaleImagePresentationToFit(in boundsInMeters: BoundingBox) {
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
    private func updateInputPlane(in boundsInMeters: BoundingBox) {
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

// MARK: - Swipe Gesture Modifiers

/// Adds a drag gesture for swipe navigation on standard SwiftUI views (GIF, 2D image)
private struct SwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 30)
                    .onChanged { value in
                        onChanged(value.translation.width)
                    }
                    .onEnded { value in
                        onEnded(value.translation.width, value.predictedEndTranslation.width)
                    }
            )
        } else {
            content
        }
    }
}

/// Adds a targeted entity drag gesture for swipe navigation on RealityKit views
private struct EntitySwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 30)
                    .targetedToAnyEntity()
                    .onChanged { value in
                        onChanged(value.translation.width)
                    }
                    .onEnded { value in
                        onEnded(value.translation.width, value.predictedEndTranslation.width)
                    }
            )
        } else {
            content
        }
    }
}
