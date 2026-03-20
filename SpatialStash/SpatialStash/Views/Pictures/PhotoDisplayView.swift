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
    @Environment(\.surfaceSnappingInfo) private var snappingInfo: SurfaceSnappingInfo
    @Environment(\.scenePhase) private var scenePhase

    /// Whether swipe navigation between gallery images is enabled
    let enableSwipeNavigation: Bool

    /// Effective swipe navigation state: disabled when window is snapped to a surface
    private var isSwipeEnabled: Bool {
        enableSwipeNavigation && !snappingInfo.isSnapped
    }

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

    /// Task for delayed window size verification (catches restoration timing issues)
    @State private var sizeVerificationTask: Task<Void, Never>?

    /// Minimum drag fraction of container width to trigger swipe
    private let swipeThresholdFraction: CGFloat = 0.3

    /// Very large window size for immersive mode (fills field of vision)
    private let immersiveWindowSize: CGSize = CGSize(width: 3000, height: 3000)

    /// The bounds used to fit images into — starts as saved window size or main window size, then tracks viewer size
    private var currentBounds: CGSize {
        viewerWindowSize ?? windowModel.savedWindowSize ?? appModel.mainWindowSize
    }

    var body: some View {
        ZStack {
            imageContent
                .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                .offset(x: dragOffset)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewerWindowSize = geo.size
                        containerWidth = geo.size.width
                        // If image is already loaded but window may be mis-sized (restoration case)
                        if windowModel.displayTexture != nil || windowModel.displayImage != nil || windowModel.isAnimatedGIF || windowModel.is3DMode {
                            scheduleWindowSizeVerification()
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        viewerWindowSize = newSize
                        containerWidth = newSize.width
                        windowModel.handleWindowResize(newSize)
                    }
            }
        )
        .onAppear {
            // Schedule post-restoration size verification (initial 2D load is
            // handled sequentially by PhotoWindowModel.start())
            scheduleWindowSizeVerification()
        }
        .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
            if wasLoading && !isLoading && !isSwipeTransitioning {
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
        .onChange(of: windowModel.slideshowTransitionDirection) { _, direction in
            guard let direction else { return }
            performSlideshowTransition(direction: direction)
        }
        // MARK: - Scene Phase Idle Downscale
        .onChange(of: scenePhase) { oldPhase, newPhase in
            windowModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        if windowModel.isAnimatedGIF, let hevcURL = windowModel.gifHEVCURL {
            // Display converted GIF as video using the shared web video player
            WebVideoPlayerView(
                videoURL: hevcURL,
                apiKey: nil,
                showControls: !windowModel.isUIHidden,
                isRoomActive: windowModel.isInActiveRoom
            )
            .brightness(windowModel.effectiveAdjustments.brightness)
            .contrast(windowModel.effectiveAdjustments.contrast)
            .saturation(windowModel.effectiveAdjustments.saturation)
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
            .overlay {
                // Transparent tap target to re-show photo ornaments when UI is hidden.
                // When visible, taps pass through to the HTML video controls instead.
                if windowModel.isUIHidden {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            windowModel.toggleUIVisibility()
                        }
                }
            }
            .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
            .onAppear {
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
            }
            .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                guard !suppressWindowResize else { return }
                resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
            }
            .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                if wasLoading && !isLoading {
                    resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    scheduleWindowSizeVerification()
                }
            }
        } else if windowModel.isAnimatedGIF {
            // GIF detected but HEVC conversion still in progress — show loading indicator
            ZStack {
                Color.black
                ProgressView("Converting...")
                    .foregroundStyle(.white)
            }
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
            .onAppear {
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
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

                    // Only handle 3D generation when in explicit 3D mode.
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
                .modifier(EntitySwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
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
                .onChange(of: windowModel.immersiveResizeTrigger) { _, _ in
                    // Triggered when entering or exiting immersive mode
                    guard !suppressWindowResize else { return }
                    
                    // Check the component's desiredViewingMode to see if we're going immersive
                    if let component = windowModel.contentEntity.components[ImagePresentationComponent.self] {
                        let isImmersive = component.desiredViewingMode == .spatial3DImmersive
                        
                        if isImmersive {
                            // Store current size before entering immersive
                            windowModel.preImmersiveWindowSize = viewerWindowSize ?? currentBounds
                            resizeWindowToFit(windowModel.imageAspectRatio, within: immersiveWindowSize, forceImmersive: true)
                        } else {
                            // Exiting immersive - restore original size
                            let restoreSize = windowModel.preImmersiveWindowSize ?? appModel.mainWindowSize
                            resizeWindowToFit(windowModel.imageAspectRatio, within: restoreSize, forceImmersive: false)
                            windowModel.preImmersiveWindowSize = nil
                        }
                    }
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
            }
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(
                cornerRadius: (appModel.roundedCorners && !windowModel.isViewingSpatial3DImmersive) ? 50 : 0,
                style: .continuous
            ))
        } else if let texture = windowModel.displayTexture {
            // GPU-backed 2D display using Metal (texture lives in GPU private memory,
            // not counted as dirty CPU pages — reduces jetsam pressure significantly)
            MetalImageView(
                texture: texture,
                brightness: Float(windowModel.effectiveAdjustments.brightness),
                contrast: Float(windowModel.effectiveAdjustments.contrast),
                saturation: Float(windowModel.effectiveAdjustments.saturation)
            )
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
            .contentShape(.rect)
            .onTapGesture {
                windowModel.toggleUIVisibility()
            }
            .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
            .onAppear {
                setUniformResizing()
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
            }
            .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                guard !suppressWindowResize else { return }
                resizeWindowToFit(newAspectRatio, within: currentBounds)
            }
            .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                if wasLoading && !isLoading {
                    resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                    scheduleWindowSizeVerification()
                }
            }
        } else if let uiImage = windowModel.displayImage {
            // Fallback: lightweight 2D display with UIImage (used for idle-downscale thumbnails
            // and 3D adjustment previews where Metal overhead isn't justified)
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
                .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
                .onAppear {
                    setUniformResizing()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
        }
    }

    // MARK: - Swipe Gesture Handling

    private func handleDragEnded(translation: CGFloat, predictedEnd: CGFloat) {
        guard !isSwipeTransitioning && !windowModel.isLoadingDetailImage && !windowModel.isSlideshowActive else {
            return
        }

        let threshold = max(containerWidth * swipeThresholdFraction, 80)
        let actualDistance = abs(translation)

        // Only allow predicted velocity to assist if the finger has already moved at least 40% of the threshold
        let velocityAssistMinimum = threshold * 0.4
        let shouldNavigateNext: Bool
        let shouldNavigatePrevious: Bool

        if actualDistance >= velocityAssistMinimum {
            shouldNavigateNext = (translation < -threshold || predictedEnd < -threshold * 2) && windowModel.hasNextGalleryImage
            shouldNavigatePrevious = (translation > threshold || predictedEnd > threshold * 2) && windowModel.hasPreviousGalleryImage
        } else {
            // Too little movement — only commit if past the full threshold (no velocity assist)
            shouldNavigateNext = translation < -threshold && windowModel.hasNextGalleryImage
            shouldNavigatePrevious = translation > threshold && windowModel.hasPreviousGalleryImage
        }

        if shouldNavigateNext {
            performSwipeTransition(direction: .next)
        } else if shouldNavigatePrevious {
            performSwipeTransition(direction: .previous)
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

        Task { @MainActor in
            // Wait for off-screen animation to complete
            try? await Task.sleep(for: .milliseconds(220))

            // Phase 2: Switch to new image (await ensures image data is ready)
            if direction == .next {
                await windowModel.nextGalleryImage()
            } else {
                await windowModel.previousGalleryImage()
            }

            // Position new image on opposite side without animation
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragOffset = -offScreenOffset
            }

            // Brief pause to let SwiftUI process the view update
            try? await Task.sleep(for: .milliseconds(50))

            // Phase 3: Animate new image sliding to center
            withAnimation(.easeOut(duration: 0.25)) {
                dragOffset = 0
            }

            // Wait for slide-in animation to complete
            try? await Task.sleep(for: .milliseconds(270))

            // Phase 4: Clear transition state and resize window
            isSwipeTransitioning = false
            suppressWindowResize = false
            if windowModel.isAnimatedGIF {
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            } else {
                resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            }
        }
    }

    private func performSlideshowTransition(direction: PhotoWindowModel.SlideshowTransitionDirection) {
        isSwipeTransitioning = true
        suppressWindowResize = true
        let offScreenOffset: CGFloat = direction == .next ? -containerWidth : containerWidth

        // Phase 1: Animate current image off-screen
        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = offScreenOffset
        }

        Task { @MainActor in
            // Wait for off-screen animation to complete
            try? await Task.sleep(for: .milliseconds(220))

            // Phase 2: Switch to new slideshow image
            await windowModel.performSlideshowSwitch(direction: direction)

            // Position new image on opposite side without animation
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragOffset = -offScreenOffset
            }

            // Brief pause to let SwiftUI process the view update
            try? await Task.sleep(for: .milliseconds(50))

            // Phase 3: Animate new image sliding to center
            withAnimation(.easeOut(duration: 0.25)) {
                dragOffset = 0
            }

            // Wait for slide-in animation to complete
            try? await Task.sleep(for: .milliseconds(270))

            // Phase 4: Clear transition state and resize window
            isSwipeTransitioning = false
            suppressWindowResize = false
            if windowModel.isAnimatedGIF {
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            } else {
                resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            }

            // Signal model that transition is complete (triggers preloading)
            windowModel.slideshowTransitionCompleted()
        }
    }

    // MARK: - Window Sizing

    /// Calculate window size for image aspect ratio using the larger dimension of
    /// the bounds. This prevents shrinking when switching between tall and wide images
    /// (e.g. a tall 600×900 window switching to a wide image would otherwise cap at 600 wide).
    private func windowSize(for aspectRatio: CGFloat, within bounds: CGSize) -> CGSize {
        let maxDim = max(bounds.width, bounds.height)
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        if aspectRatio >= 1.0 {
            // Wide or square image: width is the dominant axis
            imageWidth = maxDim
            imageHeight = maxDim / aspectRatio
        } else {
            // Tall image: height is the dominant axis
            imageWidth = maxDim * aspectRatio
            imageHeight = maxDim
        }
        return CGSize(width: imageWidth, height: imageHeight)
    }

    /// Resize window to fit image aspect ratio within given bounds
    private func resizeWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize, forceImmersive: Bool? = nil) {
        guard let windowScene = resolvedWindowScene else { return }

        // Use explicit immersive flag if provided, otherwise detect automatically
        let shouldUseImmersive: Bool
        if let forceImmersive {
            shouldUseImmersive = forceImmersive
        } else {
            shouldUseImmersive = windowModel.isViewingSpatial3DImmersive
        }
        
        let effectiveBounds = shouldUseImmersive ? immersiveWindowSize : bounds
        let size = windowSize(for: aspectRatio, within: effectiveBounds)
        
        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size))
        }
    }

    /// Resize GIF window to fit image aspect ratio within given bounds (with uniform restrictions)
    private func resizeGIFWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize) {
        guard let windowScene = resolvedWindowScene else { return }

        // Use the same windowSize helper for consistent sizing
        let size = windowSize(for: aspectRatio, within: bounds)
        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }

    /// Schedule a delayed check that the window size matches the loaded image content.
    /// Catches cases where requestGeometryUpdate was ignored during window restoration.
    private func scheduleWindowSizeVerification() {
        sizeVerificationTask?.cancel()
        sizeVerificationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            verifyWindowSizeMatchesContent()
        }
    }

    /// Verify the window size matches the loaded image's aspect ratio and saved size.
    /// If they differ by more than 5%, re-trigger resize using the saved window size
    /// (if available) to restore the user's previous window dimensions after reboot.
    private func verifyWindowSizeMatchesContent() {
        guard let currentSize = viewerWindowSize,
              windowModel.imageAspectRatio > 0,
              !windowModel.isLoadingDetailImage,
              !suppressWindowResize else { return }

        // Use saved window size as the target bounds when available — this ensures
        // post-reboot restoration uses the persisted size rather than the scene default.
        let targetBounds = windowModel.savedWindowSize ?? currentBounds

        // Compare the current window against the expected size for the image AR within target bounds
        let expectedSize = windowSize(for: windowModel.imageAspectRatio, within: targetBounds)
        let widthRatio = currentSize.width / expectedSize.width
        let heightRatio = currentSize.height / expectedSize.height

        guard widthRatio < 0.95 || widthRatio > 1.05 || heightRatio < 0.95 || heightRatio > 1.05 else { return }

        AppLogger.views.info("Window size mismatch detected (current: \(currentSize.width, privacy: .public)x\(currentSize.height, privacy: .public), expected: \(expectedSize.width, privacy: .public)x\(expectedSize.height, privacy: .public)). Resizing.")
        if windowModel.isAnimatedGIF {
            resizeGIFWindowToFit(windowModel.imageAspectRatio, within: targetBounds)
        } else {
            resizeWindowToFit(windowModel.imageAspectRatio, within: targetBounds)
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

/// Adds a drag gesture for swipe navigation on standard SwiftUI views (GIF, 2D image).
/// Uses discrete detection (onEnded only) to avoid per-frame offset flicker on visionOS.
private struct SwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        onEnded(value.translation.width, value.predictedEndTranslation.width)
                    }
            )
        } else {
            content
        }
    }
}

/// Adds a targeted entity drag gesture for swipe navigation on RealityKit views.
/// Uses discrete detection (onEnded only) to avoid per-frame offset flicker on visionOS.
private struct EntitySwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 30)
                    .targetedToAnyEntity()
                    .onEnded { value in
                        onEnded(value.translation.width, value.predictedEndTranslation.width)
                    }
            )
        } else {
            content
        }
    }
}
