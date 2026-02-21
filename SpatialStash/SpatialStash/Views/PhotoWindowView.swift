/*
 Spatial Stash - Photo Window View

 Standalone window view for displaying individual photos.
 Each photo opens in its own window with independent state.

 Memory strategy: Images display in lightweight 2D mode (SwiftUI Image with
 downsampled UIImage) by default. RealityKit is only activated when the user
 explicitly requests 3D. On window resize, the 2D image is re-downsampled
 in memory with a 1-second debounce.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct PhotoWindowView: View {
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

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

    init(image: GalleryImage, appModel: AppModel) {
        _windowModel = State(initialValue: PhotoWindowModel(image: image, appModel: appModel))
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
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                PhotoWindowOrnament(windowModel: windowModel)
            }
        )
        .onAppear {
            windowModel.startAutoHideTimer()
            // Load initial 2D display image at the default window size
            if !windowModel.isAnimatedGIF && windowModel.displayImage == nil && !windowModel.is3DMode {
                Task {
                    await windowModel.loadDisplayImage(for: appModel.mainWindowSize)
                }
            }
        }
        .onDisappear {
            windowModel.cleanup()
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

                    // If user clicked "Generate 3D", generate immediately
                    if windowModel.pendingGenerate3D {
                        windowModel.pendingGenerate3D = false
                        await windowModel.generateSpatial3DImage()
                    } else {
                        await windowModel.autoGenerateSpatial3DIfNeeded()
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

    private func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
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
    @State private var showMediaInfo = false
    @State private var isUpdatingMediaInfo = false

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
                            // Cancel generation or deactivate 3D entirely —
                            // releases the full-res GPU texture and returns
                            // to lightweight 2D display
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

                // Star rating / O counter popover button
                if windowModel.image.stashId != nil {
                    Divider()
                        .frame(height: 24)

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
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}
