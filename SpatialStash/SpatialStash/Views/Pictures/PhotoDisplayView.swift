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
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Whether swipe navigation between gallery images is enabled
    let enableSwipeNavigation: Bool

    /// User's persisted custom window size from the scene-restoration archive.
    /// Non-nil only for standalone pop-outs that were resized in a prior session;
    /// when set, it takes priority over aspect-ratio sizing on appear so a
    /// wall-snapped window restores to the exact size the user left it.
    var restoredSize: CGSize? = nil

    /// Writes the resolved window size back into the Codable window value so
    /// visionOS persists it for the next cold relaunch. Debounced via the
    /// geometry-change handler. Nil for windows that don't persist size.
    var onSizeSettled: ((CGSize) -> Void)? = nil

    /// Effective swipe navigation state: disabled when window is snapped to a surface,
    /// and only active while the viewer's UI chrome is visible so swipes don't fire
    /// during the hidden-chrome immersive state.
    private var isSwipeEnabled: Bool {
        enableSwipeNavigation
            && !snappingInfo.isSnapped
            && !windowModel.isUIHidden
    }

    /// Tracks the viewer window's current size (updated live via GeometryReader)
    @State private var viewerWindowSize: CGSize?

    /// Parity flag for the IPC calibration nudge — each call toggles this and
    /// uses it to pick a +1pt or -1pt nudge direction, so the visible motion
    /// alternates and doesn't drift in one direction over many invocations.
    @State private var nudgeAlternator: Bool = false

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

    /// Debounce task for persisting the resolved window size back into the
    /// Codable window value (scene-restoration write-back).
    @State private var sizeWritebackTask: Task<Void, Never>?

    /// True once the restored size has been applied on appear, so the
    /// aspect-ratio / verifier resize paths defer to it during launch.
    @State private var didApplyRestoredSize: Bool = false

    /// Minimum drag fraction of container width to trigger swipe
    private let swipeThresholdFraction: CGFloat = 0.2

    /// Very large window size for immersive mode (fills field of vision)
    private let immersiveWindowSize: CGSize = CGSize(width: 3000, height: 3000)

    /// The bounds used to fit images into — starts as saved window size or main window size, then tracks viewer size
    private var currentBounds: CGSize {
        // While restoring a persisted size on launch, fit images into the
        // restored bounds rather than the OS-supplied scene default — visionOS
        // sets `viewerWindowSize` to `.defaultSize` before our geometry request
        // resolves, so the image-load resize would otherwise fit to the default.
        if didApplyRestoredSize, let restoredSize {
            return restoredSize
        }
        return viewerWindowSize ?? windowModel.savedWindowSize ?? appModel.mainWindowSize
    }

    private var animatedImageAuth: (apiKey: String?, token: String?) {
        let raw = appModel.stashAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return (nil, nil) }

        let lower = raw.lowercased()
        if lower.hasPrefix("bearer ") {
            let token = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? (nil, nil) : (nil, token)
        }

        return (raw, nil)
    }

    var body: some View {
        ZStack {
            imageContent
                .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                .offset(x: dragOffset)

            // Diorama layers — backdrop at the window plane, foreground popped
            // forward in z. The ornament has its own z-offset to float above.
            // Wrapped in a Group so a single .animation modifier drives the
            // fade-in transition when the diorama layers appear (e.g. after
            // fire-and-forget generation completes during a gallery swipe).
            Group {
            if windowModel.isDioramaMode,
               !windowModel.is3DMode,
               !windowModel.isViewingSpatial3DImmersive,
               !windowModel.isAnimatedGIF {
                if let backdrop = windowModel.dioramaBackdropTexture {
                    MetalImageView(
                        texture: backdrop,
                        brightness: Float(windowModel.effectiveAdjustments.brightness),
                        contrast: Float(windowModel.effectiveAdjustments.contrast),
                        saturation: Float(windowModel.effectiveAdjustments.saturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                        .opacity(windowModel.effectiveAdjustments.opacity)
                        .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                        .offset(x: dragOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let foreground = windowModel.dioramaForegroundTexture {
                    MetalImageView(
                        texture: foreground,
                        brightness: Float(windowModel.effectiveAdjustments.brightness),
                        contrast: Float(windowModel.effectiveAdjustments.contrast),
                        saturation: Float(windowModel.effectiveAdjustments.saturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                        .opacity(windowModel.effectiveAdjustments.opacity)
                        .scaleEffect(x: windowModel.isImageFlipped ? -1 : 1, y: 1)
                        .offset(x: dragOffset)
                        .offset(z: appModel.dioramaDistance)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            }
            .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: windowModel.isDioramaMode)
            .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: windowModel.dioramaForegroundTexture != nil)

            // 3D restore prompt pill at the bottom
            if windowModel.showAutoRestorePrompt {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "view.3d")
                            .font(.body)
                        Text("Switch to \(windowModel.autoRestoreImmersive ? "immersive 3D" : "3D")?")
                            .font(.callout)
                            .lineLimit(1)

                        Button {
                            let url = windowModel.imageURL
                            windowModel.dismissAutoRestorePrompt()
                            Task {
                                await ImageEnhancementTracker.shared.setLastViewingMode(url: url, mode: .mono)
                            }
                        } label: {
                            Text("Never")
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            windowModel.dismissAutoRestorePrompt()
                            Task {
                                let mode: ImagePresentationComponent.ViewingMode = windowModel.autoRestoreImmersive ? .spatial3DImmersive : .spatial3D
                                await windowModel.switchToViewingMode(mode)
                            }
                        } label: {
                            Text("Yes")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            windowModel.dismissAutoRestorePrompt()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassBackgroundEffect(in: Capsule())
                    .padding(.bottom, 80) // clear the ornament
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: windowModel.showAutoRestorePrompt)
                // Match the ornament's z-offset so the pill stays above the
                // diorama foreground (which sits at appModel.dioramaDistance).
                .offset(z: windowModel.isDioramaMode ? 30 : 0)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewerWindowSize = geo.size
                        containerWidth = geo.size.width
                        // If image is already loaded but window may be mis-sized (restoration case)
                        if windowModel.displayTexture != nil || windowModel.displayImage != nil || windowModel.isAnimatedImage || windowModel.is3DMode {
                            scheduleWindowSizeVerification()
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        viewerWindowSize = newSize
                        containerWidth = newSize.width
                        windowModel.handleWindowResize(newSize)
                        scheduleSizeWriteback(newSize)
                    }
            }
        )
        .onAppear {
            // Restore the user's custom window size from the scene-restoration
            // archive. This wins over aspect-ratio sizing: visionOS restores
            // wall-snapped windows at the scene `.defaultSize`, so we reassert
            // the persisted size and suppress the aspect-driven resize paths for
            // ~1s so they don't stomp it before the OS resolves the request.
            applyRestoredSizeIfNeeded()
            // Schedule post-restoration size verification (initial 2D load is
            // handled sequentially by PhotoWindowModel.start())
            scheduleWindowSizeVerification()
            windowModel.isWindowSnapped = snappingInfo.isSnapped
        }
        .onChange(of: snappingInfo.isSnapped) { _, isSnapped in
            windowModel.isWindowSnapped = isSnapped
            if isSnapped {
                windowModel.dismissAutoRestorePrompt()
            }
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
        .onChange(of: windowModel.hostFullyImmersiveSpace) { _, isOpen in
            // The photo window stays open and doubles as the controls
            // anchor — its RealityView content is hidden by an opacity
            // gate so the user only sees the ornament + immersive scene.
            Task {
                if isOpen {
                    // Loan the windowed IPC entity to the immersive scene
                    // so RealityKit reuses the already-generated
                    // Spatial3DImage instead of regenerating + double-
                    // allocating GPU resources.
                    appModel.immersiveLoanEntity = windowModel.contentEntity
                    appModel.immersiveLoanOwner = windowModel
                    let value = Spatial3DImmersiveValue(imageURL: windowModel.imageURL)
                    _ = await openImmersiveSpace(value: value)
                    windowModel.cancelAutoHideTimer()
                    windowModel.isUIHidden = false
                } else {
                    await dismissImmersiveSpace()
                    // Flip the IPC back to windowed spatial3D so the
                    // photo window's RealityView re-adopts the entity at
                    // the correct viewing mode (the update closure's
                    // `parent == nil` guard handles the re-attach).
                    if var ipc = windowModel.contentEntity.components[ImagePresentationComponent.self] {
                        ipc.desiredViewingMode = .spatial3D
                        windowModel.desiredViewingMode = .spatial3D
                        windowModel.contentEntity.components.set(ipc)
                    }
                    // Reset the transform — it was carrying the
                    // immersive world pose (eye-height Y, ~2m -Z) which,
                    // applied as window-local on re-adoption, slid the
                    // entity up and out of the window's visible bounds.
                    // The windowed update closure recomputes scale +
                    // position correctly on its next pass.
                    windowModel.contentEntity.transform = Transform()
                    appModel.immersiveLoanEntity = nil
                    if appModel.immersiveLoanOwner === windowModel {
                        appModel.immersiveLoanOwner = nil
                    }
                    windowModel.startAutoHideTimer()
                }
            }
        }
        .onDisappear {
            if windowModel.hostFullyImmersiveSpace {
                windowModel.hostFullyImmersiveSpace = false
                appModel.immersiveLoanEntity = nil
                if appModel.immersiveLoanOwner === windowModel {
                    appModel.immersiveLoanOwner = nil
                }
                Task { await dismissImmersiveSpace() }
            }
        }
        // MARK: - Scene Phase Idle Downscale
        .onChange(of: scenePhase) { oldPhase, newPhase in
            windowModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
            // When the window comes back to the foreground, IPC's off-axis
            // calibration is likely stale — kick a nudge to clear any blur.
            // No-op unless the photo is currently in windowed spatial3D.
            if newPhase == .active && oldPhase != .active {
                windowModel.refreshSpatial3DCalibration()
            }
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
            .opacity(windowModel.effectiveAdjustments.opacity)
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
        } else if windowModel.isAnimatedWebP || windowModel.isAnimatedWebVisual {
            AnimatedImageWebView(
                imageURL: windowModel.animatedImageSourceURL ?? windowModel.imageURL,
                elementType: windowModel.isAnimatedWebVisual ? .video : .image,
                apiKey: animatedImageAuth.apiKey,
                authorizationToken: animatedImageAuth.token
            )
                .brightness(windowModel.effectiveAdjustments.brightness)
                .contrast(windowModel.effectiveAdjustments.contrast)
                .saturation(windowModel.effectiveAdjustments.saturation)
                .opacity(windowModel.effectiveAdjustments.opacity)
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
                .overlay {
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
                    if windowModel.contentEntity.parent == nil {
                        content.add(windowModel.contentEntity)
                    }
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
                    // While Fully Immersive 3D owns the entity, the
                    // immersive scene is the one mutating its transform —
                    // any setPosition/scale here would clobber the
                    // placement every frame and snap the IPC back to the
                    // (hidden) photo window's pose.
                    guard !windowModel.hostFullyImmersiveSpace else { return }
                    guard let presentationScreenSize = windowModel
                        .contentEntity
                        .observable
                        .components[ImagePresentationComponent.self]?
                        .presentationScreenSize, presentationScreenSize != .zero else {
                            return
                    }
                    let originalPosition = windowModel.contentEntity.position(relativeTo: nil)
                    // Experimental: recess the spatial3D scene slightly behind the
                    // window glass to mask the off-axis comfort-cone falloff. Pairs
                    // with the soft BillboardComponent set by updateExperimentalSpatial3DTuning().
                    let experimentalZ: Float = windowModel.shouldApplyExperimentalSpatial3DTuning
                        ? PhotoWindowModel.experimentalSpatial3DZInset
                        : 0.0
                    windowModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, experimentalZ), relativeTo: nil)
                    let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                    scaleImagePresentationToFit(in: availableBounds)
                    if windowModel.contentEntity.parent == nil {
                        content.add(windowModel.contentEntity)
                    }
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
                            // Refresh IPC's off-axis calibration on every tap
                            // — cheap and matches the manual-resize fix the
                            // user would otherwise need to do themselves.
                            windowModel.refreshSpatial3DCalibration()
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
                .onChange(of: windowModel.calibrationNudgeTrigger) { _, _ in
                    nudgeWindowSizeForCalibration()
                }
            }
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            // Hide the windowed RealityKit presentation while the Fully
            // Immersive space is hosting the IPC — the photo window stays
            // as a controls anchor (ornament + chrome) but doesn't double
            // up the spatial scene.
            .opacity(windowModel.hostFullyImmersiveSpace ? 0 : windowModel.effectiveAdjustments.opacity)
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
                saturation: Float(windowModel.effectiveAdjustments.saturation),
                sharpen: Float(windowModel.effectiveAdjustments.sharpen)
            )
            .opacity(windowModel.effectiveAdjustments.opacity)
            .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
            .contentShape(.rect)
            .onTapGesture {
                windowModel.toggleUIVisibility()
            }
            .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
            .onAppear {
                // The 3D-adjustment 2D preview re-mounts this branch
                // every time is3DMode flips false. Re-running the
                // initial-size resize would shrink the window back to
                // its saved 2D bounds (often much smaller than the
                // current 3D window) and the geometry change would
                // also instantly dismiss the open adjustments popover.
                // Leave the window alone during the preview.
                guard !windowModel.isShowingAdjustmentPreview else { return }
                setUniformResizing()
                let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
            }
            .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                guard !suppressWindowResize, !windowModel.isShowingAdjustmentPreview else { return }
                resizeWindowToFit(newAspectRatio, within: currentBounds)
            }
            .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                if wasLoading && !isLoading, !windowModel.isShowingAdjustmentPreview {
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
            .opacity(windowModel.effectiveAdjustments.opacity)
                .clipShape(RoundedRectangle(cornerRadius: appModel.roundedCorners ? 50 : 0, style: .continuous))
                .contentShape(.rect)
                .onTapGesture {
                    windowModel.toggleUIVisibility()
                }
                .modifier(SwipeGestureModifier(enabled: isSwipeEnabled, onEnded: handleDragEnded))
                .onAppear {
                    // Same rationale as the MetalImageView branch above —
                    // the adjustments preview re-mounts this branch, and
                    // resizing here would both shrink the window and
                    // instantly dismiss the open popover.
                    guard !windowModel.isShowingAdjustmentPreview else { return }
                    setUniformResizing()
                    let initialBounds = windowModel.savedWindowSize ?? appModel.mainWindowSize
                    resizeWindowToFit(windowModel.imageAspectRatio, within: initialBounds)
                }
                .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                    guard !suppressWindowResize, !windowModel.isShowingAdjustmentPreview else { return }
                    resizeWindowToFit(newAspectRatio, within: currentBounds)
                }
                .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                    if wasLoading && !isLoading, !windowModel.isShowingAdjustmentPreview {
                        resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        scheduleWindowSizeVerification()
                    }
                }
        }
    }

    // MARK: - Swipe Gesture Handling

    private func handleDragEnded(translation: CGFloat, predictedEnd: CGFloat) {
        guard !isSwipeTransitioning && !windowModel.isLoadingDetailImage else {
            return
        }

        let threshold = max(containerWidth * swipeThresholdFraction, 54)
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
        let reduceMotion = appModel.effectiveReduceMotion

        // Phase 1: Animate current image off-screen (skipped under reduce motion)
        if reduceMotion {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dragOffset = 0 }
        } else {
            withAnimation(.easeIn(duration: 0.2)) {
                dragOffset = offScreenOffset
            }
        }

        Task { @MainActor in
            // Wait for off-screen animation to complete
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }

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
                dragOffset = reduceMotion ? 0 : -offScreenOffset
            }

            // Brief pause to let SwiftUI process the view update
            try? await Task.sleep(for: .milliseconds(50))

            // Phase 3: Animate new image sliding to center
            if reduceMotion {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { dragOffset = 0 }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    dragOffset = 0
                }
            }

            // Wait for slide-in animation to complete
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(270))
            }

            // Phase 4: Clear transition state and resize window
            isSwipeTransitioning = false
            suppressWindowResize = false
            if windowModel.isAnimatedImage {
                resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            } else {
                resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
            }
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

    /// Alternating 1pt nudge: each call moves the window by -1pt OR +1pt
    /// (alternating between calls), then reverts to the base size. Halves
    /// the visible motion of the previous shrink-then-grow round-trip since
    /// only one transition is visible per call. Direction alternates so the
    /// nudge looks symmetric over time and doesn't drift in one direction.
    private func nudgeWindowSizeForCalibration() {
        guard let windowScene = resolvedWindowScene else { return }
        let base = viewerWindowSize ?? currentBounds
        guard base.width > 2, base.height > 2 else { return }
        let delta: CGFloat = nudgeAlternator ? 1 : -1
        nudgeAlternator.toggle()
        let nudged = CGSize(width: base.width + delta, height: base.height + delta)
        Task { @MainActor in
            UIView.performWithoutAnimation {
                windowScene.requestGeometryUpdate(.Vision(size: nudged))
            }
            try? await Task.sleep(for: .milliseconds(150))
            UIView.performWithoutAnimation {
                windowScene.requestGeometryUpdate(.Vision(size: base))
            }
        }
    }

    /// Apply the persisted custom window size (if any) on appear. Requests the
    /// geometry immediately and holds `suppressWindowResize` for ~1s so the
    /// aspect-ratio and verifier resize paths defer to the restored size until
    /// the OS has resolved the request. No-op when there is no persisted size.
    private func applyRestoredSizeIfNeeded() {
        guard let restoredSize, restoredSize.width > 2, restoredSize.height > 2 else { return }
        guard let windowScene = resolvedWindowScene else { return }
        didApplyRestoredSize = true
        suppressWindowResize = true
        UIView.performWithoutAnimation {
            if windowModel.isAnimatedImage {
                windowScene.requestGeometryUpdate(.Vision(size: restoredSize, resizingRestrictions: .uniform))
            } else {
                windowScene.requestGeometryUpdate(.Vision(size: restoredSize))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            suppressWindowResize = false
            didApplyRestoredSize = false
        }
    }

    /// Debounce a write-back of the resolved window size into the Codable window
    /// value so visionOS persists it for the next cold relaunch. Skipped while
    /// `suppressWindowResize` is set (during restored-size apply / swipe
    /// transitions) so a transient default size isn't persisted over the user's.
    private func scheduleSizeWriteback(_ size: CGSize) {
        guard let onSizeSettled else { return }
        guard !suppressWindowResize, size.width > 2, size.height > 2 else { return }
        sizeWritebackTask?.cancel()
        sizeWritebackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onSizeSettled(size)
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

        // Prefer the per-window restored size (from the scene archive) over the
        // per-image saved size — this ensures post-reboot restoration uses the
        // exact size the user left this window at rather than the scene default
        // or a different window's size for the same image.
        let targetBounds = restoredSize ?? windowModel.savedWindowSize ?? currentBounds

        // Compare the current window against the expected size for the image AR within target bounds
        let expectedSize = windowSize(for: windowModel.imageAspectRatio, within: targetBounds)
        let widthRatio = currentSize.width / expectedSize.width
        let heightRatio = currentSize.height / expectedSize.height

        guard widthRatio < 0.95 || widthRatio > 1.05 || heightRatio < 0.95 || heightRatio > 1.05 else { return }

        AppLogger.views.info("Window size mismatch detected (current: \(currentSize.width, privacy: .public)x\(currentSize.height, privacy: .public), expected: \(expectedSize.width, privacy: .public)x\(expectedSize.height, privacy: .public)). Resizing.")
        if windowModel.isAnimatedImage {
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

    // Keep view identity stable across `enabled` flips: an if/else here
    // produces a _ConditionalContent whose branch swap reroots the wrapped
    // view. On the RealityKit 3D path that tears down the
    // ImagePresentationComponent and the immersive window vanishes when the
    // ornament auto-hides.
    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard enabled else { return }
                    onEnded(value.translation.width, value.predictedEndTranslation.width)
                }
        )
    }
}

/// Adds a targeted entity drag gesture for swipe navigation on RealityKit views.
/// Uses discrete detection (onEnded only) to avoid per-frame offset flicker on visionOS.
private struct EntitySwipeGestureModifier: ViewModifier {
    let enabled: Bool
    let onEnded: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 20)
                .targetedToAnyEntity()
                .onEnded { value in
                    guard enabled else { return }
                    onEnded(value.translation.width, value.predictedEndTranslation.width)
                }
        )
    }
}
