/*
 Spatial Stash - Remote Viewer Window View

 Main viewer window that displays a slideshow of images from the
 remote API with clock, sensor overlays, Ken Burns animation,
 and ornament controls.
 */

import Combine
import os
import SwiftUI

struct RemoteViewerWindowView: View {
    let windowValue: RemoteViewerWindowValue
    /// Writes the resolved window size back into the Codable window value so
    /// visionOS persists it for the next cold relaunch (scene restoration).
    var onSizeSettled: ((CGSize) -> Void)? = nil
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewerModel: RemoteViewerModel?
    @State private var showHistory = false
    @State private var windowSize: CGSize = .zero
    @State private var currentTime = Date()
    @State private var autoHideTimer: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var didArmInitialAutoHide = false
    @State private var isRestoredWindow = false
    @State private var showRestorationPlaceholder = false
    @State private var metalRendererGeneration = 0
    @State private var renderRecoveryAttempt = 0
    @State private var renderRecoveryTask: Task<Void, Never>?

    // Ken Burns animation state
    @State private var kenBurnsScale: CGFloat = 1.0
    @State private var kenBurnsOffset: CGSize = .zero

    /// Alternates the ±1pt direction of the slideshow's IPC calibration
    /// nudge so the visible motion stays symmetric over time. Mirrors the
    /// fix in PhotoDisplayView — IPC drops its off-axis blur calibration
    /// across image swaps and only a real geometry change reasserts it.
    @State private var nudgeAlternator: Bool = false

    /// Debounce task for persisting the resolved window size back into the
    /// Codable window value (scene-restoration write-back).
    @State private var sizeWritebackTask: Task<Void, Never>?

    /// True for ~1s after applying a restored size on launch, so the transient
    /// scene-default geometry isn't persisted over the user's custom size.
    @State private var suppressSizeWriteback: Bool = false

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            // When diorama is on, the foreground plane is popped forward by
            // dioramaDistance in Z. Overlays anchored at z=0 would be occluded,
            // so lift them in front of the foreground plane. Match the
            // ornament's +30pt clearance on top of the foreground offset.
            let overlayZ: CGFloat = (viewerModel?.enableDiorama ?? false)
                ? appModel.dioramaDistance + 30
                : 0
            ZStack {
                // Background
                if !(viewerModel?.config.transparentBackground ?? false) {
                    Color.black.ignoresSafeArea()
                }

                if showRestorationPlaceholder {
                    WindowRestorationPlaceholder(
                        title: "Restoring Slideshow",
                        windowID: windowValue.id,
                        status: remoteRestorationStatus
                    )
                    .offset(z: overlayZ)
                }

                // Image layers — brightness/contrast/saturation are
                // pushed into MetalImageView's fragment shader for the
                // base texture and applied as SwiftUI modifiers inside
                // imageLayer for the diorama / WKWebView / video paths
                // (which aren't Metal-backed). Opacity stays at the top
                // level so it composites the whole stack uniformly.
                if let model = viewerModel {
                    imageLayer(model: model)
                        .opacity(model.effectiveOpacity)
                }

                // Clock overlay
                if let model = viewerModel, model.showClock {
                    clockOverlay(model: model)
                        .offset(z: overlayZ)
                }

                // Sensor overlay
                if let model = viewerModel, model.showSensors, !model.sortedSensors.isEmpty {
                    sensorOverlay(model: model)
                        .offset(z: overlayZ)
                }

                // Loading indicator — only when truly nothing is on screen.
                // A video/GIF/WebP plays via its own WKWebView layer (and
                // leaves currentImage nil), so checking currentImage alone
                // would pop the spinner over a playing video while the next
                // image prefetches. Gate on the image media type too so the
                // spinner appears only when there is genuinely no media shown
                // (e.g. first paint, or space restoration of snapped windows).
                if let model = viewerModel,
                   model.isLoading, model.currentMediaType == .image, model.currentImage == nil {
                    ProgressView()
                        .scaleEffect(2)
                        .offset(z: overlayZ)
                }

                // Toast notification
                if let model = viewerModel, let toast = model.toastMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(toast)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(model.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7))
                                )
                            Spacer()
                        }
                        .padding(.bottom, 80)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut, value: model.toastMessage)
                    .offset(z: overlayZ)
                }

                // History overlay
                if showHistory, let model = viewerModel,
                   let store = appModel.remoteHistoryStore(for: model.config.apiEndpoint, accessToken: model.config.accessToken) {
                    RemoteHistoryView(
                        store: store,
                        onEntrySelected: { entry in
                            model.jumpToHistoryEntry(entry)
                            showHistory = false
                        }
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                windowSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                windowSize = newSize
                viewerModel?.updateWindowAspectRatio(newSize)
                scheduleSizeWriteback(newSize)
            }
        }
        .ornament(
            visibility: controlsVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                if let model = viewerModel, let tlm = model.tagListManager {
                    RemoteViewerOrnamentView(
                        model: model,
                        tagListManager: tlm,
                        modTagManager: appModel.modTagManager,
                        showHistory: $showHistory
                    )
                    .offset(z: model.enableDiorama ? 30 : 0)
                }
            }
        )
        .onAppear {
            isRestoredWindow = RestoredWindowTracker.isRestored(windowValue.id)
            showRestorationPlaceholder = isRestoredWindow
            AppLogger.windowState.info(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] view appeared restored=\(self.isRestoredWindow, privacy: .public) config=\(windowValue.configId.uuidString, privacy: .public) savedSize=\(String(describing: windowValue.restoredSize?.cgSize), privacy: .public)"
            )
            setupModel()
            // Wall-snapped slideshow windows restored by visionOS after a
            // reboot come back with the same windowValue UUID. Keep controls
            // visible until the first post arrives so a failed first frame
            // never leaves a transparent, non-interactive window.
            if !isRestoredWindow {
                RestoredWindowTracker.markSeen(windowValue.id)
            }
            // Restore the user's custom window size/aspect ratio from the scene
            // archive. visionOS restores wall-snapped windows at the scene
            // `.defaultSize` (1400×900), so reassert the persisted size here.
            applyRestoredSizeIfNeeded()
        }
        .onDisappear {
            if let model = viewerModel {
                appModel.unregisterRemoteViewerModel(model)
            }
            // Unregister unconditionally. Gating this on the model meant a
            // window whose config never resolved could never be unregistered,
            // so the registry kept claiming it was open forever.
            appModel.unregisterRemoteViewerWindow(configId: windowValue.configId, windowValueId: windowValue.id)
            viewerModel?.stop()
            autoHideTimer?.cancel()
            renderRecoveryTask?.cancel()
        }
        .onChange(of: viewerModel?.isTransitioning) { _, isTransitioning in
            // Refresh IPC's off-axis blur calibration mid-crossfade so
            // the window's 1pt size flicker is masked by the fade
            // itself instead of popping in once the new image is fully
            // visible. Crossfade is 1s; halfway is the visual quietest
            // point (both slots at ~0.5 opacity). No-op unless
            // slideshow 3D is active.
            guard isTransitioning == true,
                  viewerModel?.isSlideshow3DActive == true else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard viewerModel?.isSlideshow3DActive == true else { return }
                nudgeWindowSizeForCalibration()
            }
        }
        .onChange(of: viewerModel?.currentPost?.id) { _, postId in
            guard postId != nil else { return }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            viewerModel?.handleScenePhaseChange(from: oldPhase, to: newPhase)
            if newPhase == .active && oldPhase != .active, viewerModel?.isSlideshow3DActive == true {
                nudgeWindowSizeForCalibration()
            }
            // Restart Ken Burns animation on return to foreground — the SwiftUI
            // animation is time-based and continues running while backgrounded,
            // so the remaining duration would be too short without a restart.
            if newPhase == .active && oldPhase != .active, let model = viewerModel {
                if model.currentMediaType == .image && !model.isCurrentPostAnimatedGIF {
                    startKenBurnsAnimation(model: model)
                }
            }
        }
        .onReceive(clockTimer) { time in
            currentTime = time
        }
        .onChange(of: appModel.globalVisualAdjustments) { _, newValue in
            viewerModel?.globalAdjustments = newValue
        }
        .onChange(of: appModel.effectiveReduceMotion, initial: true) { _, newValue in
            viewerModel?.reduceMotion = newValue
        }
        .onChange(of: viewerModel?.showAdjustmentsPopover) { _, isOpen in
            if isOpen == true {
                autoHideTimer?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onChange(of: viewerModel?.isAnyOrnamentMenuOpen) { _, isOpen in
            if isOpen == true {
                autoHideTimer?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onChange(of: showHistory) { _, isOpen in
            guard isOpen, let model = viewerModel,
                  let store = appModel.remoteHistoryStore(for: model.config.apiEndpoint, accessToken: model.config.accessToken)
            else { return }
            Task { await store.refresh() }
        }
        .contentShape(.rect)
        .onTapGesture {
            controlsVisible.toggle()
            if controlsVisible {
                resetAutoHideTimer()
            } else {
                autoHideTimer?.cancel()
            }
            // Manual IPC blur recovery, matching the regular 3D photo
            // viewer's tap behaviour. The per-crossfade nudge already
            // covers steady-state, but a stray tap is the user's
            // expected escape hatch when calibration has drifted.
            if viewerModel?.isSlideshow3DActive == true {
                nudgeWindowSizeForCalibration()
            }
        }
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
    }

    @ViewBuilder
    private func imageLayer(model: RemoteViewerModel) -> some View {
        ZStack {
            // Static first-frame fallback for animated media (.animatedWebP via
            // WKWebView, .animatedGIF via the HEVC player). Both take a few
            // hundred ms to spin up on first creation — for GIFs the player is
            // only swapped in *after* the crossfade once HEVC conversion
            // finishes, so without this the slideshow briefly goes blank.
            // Rendered behind the live player in the ZStack so it shows through
            // until the player paints, then is visually covered by the
            // animation.
            if model.isAnimatedMediaWithStaticFallback,
               let image = model.currentImage {
                currentImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .opacity(model.isTransitioning ? 0 : 1)
                    .clipped()
            }

            // Video / animated GIF layer (WebVideoPlayerView)
            switch model.currentMediaType {
            case .video, .videoAsImage:
                // Rendered by the unified video layer below (see activeVideoURL)
                // so the player survives the image→video crossfade commit.
                EmptyView()

            case .animatedGIF(let hevcURL):
                // Backgrounded windows fall back to the static first-frame layer
                // rendered above (isAnimatedMediaWithStaticFallback). Dropping the
                // WKWebView here tears down its out-of-process WebContent/GPU
                // helpers — which don't count toward our process footprint but do
                // pin device memory — and it rebuilds on return to active.
                if model.isRoomActive {
                    WebVideoPlayerView(
                        videoURL: hevcURL,
                        apiKey: nil,
                        showControls: false,
                        isRoomActive: model.isRoomActive
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Also show the static image underneath during transition
                    .opacity(model.isTransitioning ? 0 : 1)
                    .brightness(model.effectiveBrightness)
                    .contrast(model.effectiveContrast)
                    .saturation(model.effectiveSaturation)
                }

            case .animatedWebP(let url):
                if model.isRoomActive {
                    AnimatedImageWebView(
                        imageURL: url,
                        elementType: .image,
                        apiKey: nil,
                        authorizationToken: nil,
                        imageData: model.currentAnimatedData,
                        imageDataMimeType: "image/webp"
                    )
                    .aspectRatio(model.currentImage?.size ?? CGSize(width: 1, height: 1), contentMode: .fit)
                    // Fade out during crossfade so the next image's static
                    // texture (or its own WebKit layer) takes over cleanly.
                    .opacity(model.isTransitioning ? 0 : 1)
                    .brightness(model.effectiveBrightness)
                    .contrast(model.effectiveContrast)
                    .saturation(model.effectiveSaturation)
                }

            case .animatedJXL:
                if model.isRoomActive {
                    AnimatedJXLWebView(imageData: model.currentAnimatedData)
                        .aspectRatio(model.currentImage?.size ?? CGSize(width: 1, height: 1), contentMode: .fit)
                        .opacity(model.isTransitioning ? 0 : 1)
                        .brightness(model.effectiveBrightness)
                        .contrast(model.effectiveContrast)
                        .saturation(model.effectiveSaturation)
                }

            case .image:
                EmptyView()
            }

            // Slideshow 3D path (RealityKit) — replaces the SwiftUI image
            // pipeline when the profile selects 3D / Immersive 3D. The
            // layer owns two slot entities and pre-generates the next
            // image while the current is on screen, then crossfades by
            // swapping which slot is visible.
            if model.currentMediaType == .image && model.isSlideshow3DActive {
                // Tap callback fires from a targeted-entity gesture
                // wired inside each slot's RealityView — visionOS hit-
                // tests RealityKit entities in 3D space ahead of SwiftUI
                // overlays, so SwiftUI .onTapGesture / Color.clear
                // overlays in this region never see the tap.
                // Adjustments are baked into the Spatial3DImage's source
                // bytes inside SlideshowSpatial3DSlotView — RealityKit
                // content on visionOS doesn't honor SwiftUI compositing
                // modifiers like `.brightness`, so applying them here is
                // a no-op. Cache-key-keyed regeneration in the slot view
                // handles applying new values to future images and the
                // hidden pre-generated slot.
                SlideshowSpatial3DLayer(
                    model: model,
                    onTap: {
                        controlsVisible.toggle()
                        if controlsVisible {
                            resetAutoHideTimer()
                        } else {
                            autoHideTimer?.cancel()
                        }
                        nudgeWindowSizeForCalibration()
                    },
                    onSpatial3DGenerated: { image in
                        model.notifySpatial3DGenerated(image: image)
                        markContentPresented(renderer: "RealityKit")
                    }
                )
            }

            // Current image (shown for .image type, or as static first frame while GIF converts)
            if model.currentMediaType == .image && !model.isSlideshow3DActive, let image = model.currentImage {
                let useKenBurns = model.enableKenBurns && !model.isCurrentPostAnimatedGIF
                currentImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                    .offset(useKenBurns ? kenBurnsOffset : .zero)
                    .opacity(model.isTransitioning ? 0 : 1)
                    .clipped()

                // Diorama layers — hidden whenever an ornament-anchored
                // panel is open (adjustments popover, tag-list / mod-tag
                // menus). The popped-forward foreground at z=40 would
                // otherwise occlude the menu drop-down which renders near
                // the window plane.
                let dioramaVisible = model.enableDiorama
                    && !model.showAdjustmentsPopover
                    && !model.isAnyOrnamentMenuOpen
                    && !showHistory

                // Wrapped so a single .animation modifier drives the
                // fade-in when the diorama layers materialize after
                // fire-and-forget generation, instead of snapping in.
                Group {
                    if dioramaVisible, let backdrop = model.currentBackdropTexture {
                        MetalImageView(
                            texture: backdrop,
                            brightness: Float(model.effectiveBrightness),
                            contrast: Float(model.effectiveContrast),
                            saturation: Float(model.effectiveSaturation),
                            sharpen: 0
                        )
                            .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                            .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                            .offset(useKenBurns ? kenBurnsOffset : .zero)
                            .opacity(model.isTransitioning ? 0 : 1)
                            .clipped()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if dioramaVisible, let foreground = model.currentForegroundTexture {
                        MetalImageView(
                            texture: foreground,
                            brightness: Float(model.effectiveBrightness),
                            contrast: Float(model.effectiveContrast),
                            saturation: Float(model.effectiveSaturation),
                            sharpen: 0
                        )
                            .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                            .scaleEffect(useKenBurns ? kenBurnsScale : 1.0)
                            .offset(useKenBurns ? kenBurnsOffset : .zero)
                            .opacity(model.isTransitioning ? 0 : 1)
                            .clipped()
                            .offset(z: appModel.dioramaDistance)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: dioramaVisible)
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: model.currentForegroundTexture != nil)
                .animation(appModel.effectiveReduceMotion ? nil : .easeInOut(duration: 0.5), value: model.currentBackdropTexture != nil)
            }

// Next image (fading in during transition) — skipped when slideshow 3D
            // owns the rendering since that path stacks two RealityViews.
            if !model.isSlideshow3DActive, let image = model.nextImage, model.isTransitioning {
                nextImageRenderer(model: model, image: image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .opacity(1)
                    .clipped()

                if model.enableDiorama, let backdrop = model.nextBackdropTexture {
                    MetalImageView(
                        texture: backdrop,
                        brightness: Float(model.effectiveBrightness),
                        contrast: Float(model.effectiveContrast),
                        saturation: Float(model.effectiveSaturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(backdrop.width) / CGFloat(backdrop.height), contentMode: .fit)
                        .clipped()
                        .allowsHitTesting(false)
                }
                if model.enableDiorama, let foreground = model.nextForegroundTexture {
                    MetalImageView(
                        texture: foreground,
                        brightness: Float(model.effectiveBrightness),
                        contrast: Float(model.effectiveContrast),
                        saturation: Float(model.effectiveSaturation),
                        sharpen: 0
                    )
                        .aspectRatio(CGFloat(foreground.width) / CGFloat(foreground.height), contentMode: .fit)
                        .clipped()
                        .offset(z: appModel.dioramaDistance)
                        .allowsHitTesting(false)
                }
            }

            // Unified video layer. A single WebVideoPlayerView hosts both the
            // incoming image→video crossfade slot and the committed video slot.
            // Because the view's position and `videoURL` are identical before
            // and after the crossfade commit (see `activeVideoURL`), SwiftUI
            // preserves its identity across the commit instead of destroying
            // the playing layer and creating a fresh one — which previously
            // forced a reload and a brief blank flash right after the crossfade.
            if let videoURL = model.activeVideoURL {
                let isOutgoing = model.isTransitioning && model.nextVideoURL == nil
                Group {
                    if let url3D = model.activePseudo3DVideoURL {
                        // Slideshow 3D + an installed real-time depth model:
                        // convert the mono clip to windowed stereoscopic 3D on
                        // the fly. Always `.realtime` — the pre-processed mode
                        // would write a depth video per clip to disk, and a
                        // slideshow cycles through far too much content for
                        // that. Depth here lives only as long as the frame it
                        // warps.
                        Pseudo3DVideoPlayerView(
                            videoURL: url3D,
                            isRoomActive: model.isRoomActive,
                            // RealityKit ignores SwiftUI's .brightness/.contrast/
                            // .saturation, so the slideshow's adjustments (incl.
                            // dynamic brightness) ride the warp shader instead.
                            visualAdjustments: pseudo3DAdjustments(model: model),
                            settings: appModel.globalPseudo3DSettings,
                            depthMode: .realtime,
                            loops: model.currentVideoLoops,
                            // Same reason as the adjustments: the .opacity below
                            // can't fade RealityKit content, so the crossfade is
                            // driven through the scene's OpacityComponent.
                            contentOpacity: isOutgoing ? 0 : 1,
                            onDurationKnown: { [weak model] seconds in
                                guard let model, let post = model.nextPost ?? model.currentPost else { return }
                                model.onVideoDurationKnown(seconds, for: post)
                            },
                            onPlaybackError: { [weak model] in
                                // No usable depth or the stereo pipeline can't
                                // decode this source — drop to the flat tiers.
                                model?.reportPseudo3DVideoFailure()
                            }
                        )
                    } else if model.activeVideoIsAnimatedImage {
                        // Native tier: WebKit plays H.264 in an <img>, managing
                        // playback lifecycle itself (pause / resume on room
                        // transitions) — no AVPlayer, no isRoomActive/duration
                        // wiring. If the source isn't a codec <img> can decode,
                        // onError escalates to the <video> tiers (raw → HLS).
                        AnimatedImageWebView(imageURL: videoURL, onError: { [weak model] in
                            model?.videoNativeImgFailed = true
                        })
                    } else {
                        // Fallback tiers: <video> plays the raw source natively
                        // (WebM/AV1 the device supports); on decode error it
                        // switches to the HLS stream (server-transcoded H.264).
                        WebVideoPlayerView(
                            videoURL: videoURL,
                            fallbackVideoURL: model.currentVideoHLSURL,
                            apiKey: nil,
                            showControls: false,
                            isRoomActive: model.isRoomActive,
                            onDurationKnown: { [weak model] seconds in
                                // During the image→video crossfade the incoming clip is
                                // `nextPost` — loadedmetadata usually fires before the
                                // engine commits it to `currentPost`. Attribute the
                                // duration to the post that owns the video, not whatever
                                // is still fading out.
                                guard let model, let post = model.nextPost ?? model.currentPost else { return }
                                model.onVideoDurationKnown(seconds, for: post)
                            },
                            loop: model.currentVideoLoops
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fade out only when this is the *outgoing* video (video→video
                // through black, or video→image). When a video is crossfading
                // *in* over a fading image (nextVideoURL set), it stays at full
                // opacity and the image fades beneath it.
                .opacity(isOutgoing ? 0 : 1)
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
                .onAppear {
                    markContentPresented(
                        renderer: model.activePseudo3DVideoURL != nil
                            ? "RealityKit stereo video" : "WebKit video"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.currentPost?.id) { _, _ in
            // Only animate Ken Burns for static images (not GIFs or videos)
            if model.currentMediaType == .image && !model.isCurrentPostAnimatedGIF {
                startKenBurnsAnimation(model: model)
            } else {
                resetKenBurns()
            }
        }
        .onChange(of: model.currentMediaType) { _, newType in
            // When media type changes (e.g. GIF HEVC conversion completes), reset Ken Burns
            if newType != .image {
                resetKenBurns()
            }
        }
    }

    /// Packs the slideshow's effective adjustments for the fake-3D warp shader.
    /// RealityKit content on visionOS doesn't honor SwiftUI's compositing
    /// modifiers, so brightness/contrast/saturation have to be baked into the
    /// per-eye warp the way `SlideshowSpatial3DSlotView` bakes them into the
    /// image bytes. `VisualAdjustments` declares its own init, so there's no
    /// memberwise one to call inline.
    private func pseudo3DAdjustments(model: RemoteViewerModel) -> VisualAdjustments {
        var adjustments = VisualAdjustments()
        adjustments.brightness = model.effectiveBrightness
        adjustments.contrast = model.effectiveContrast
        adjustments.saturation = model.effectiveSaturation
        return adjustments
    }

    /// Renders the current image via Metal when a GPU texture is available,
    /// otherwise falls back to a SwiftUI `Image` so the slideshow never
    /// goes blank if texture creation lags or fails. Adjustments ride the
    /// fragment-shader uniforms on the Metal path; the UIImage fallback
    /// uses SwiftUI modifiers so its output matches.
    @ViewBuilder
    private func currentImageRenderer(model: RemoteViewerModel, image: UIImage) -> some View {
        if let texture = model.currentTexture {
            MetalImageView(
                texture: texture,
                brightness: Float(model.effectiveBrightness),
                contrast: Float(model.effectiveContrast),
                saturation: Float(model.effectiveSaturation),
                sharpen: 0,
                diagnosticLabel: "remote-\(windowValue.id.uuidString.prefix(8))",
                onFramePresented: {
                    markContentPresented(renderer: "Metal")
                },
                onRenderStalled: recoverStalledRenderer
            )
            .id(metalRendererGeneration)
        } else {
            Image(uiImage: image)
                .resizable()
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
                .onAppear {
                    markContentPresented(renderer: "SwiftUI image")
                }
        }
    }

    @ViewBuilder
    private func nextImageRenderer(model: RemoteViewerModel, image: UIImage) -> some View {
        if let texture = model.nextTexture {
            MetalImageView(
                texture: texture,
                brightness: Float(model.effectiveBrightness),
                contrast: Float(model.effectiveContrast),
                saturation: Float(model.effectiveSaturation),
                sharpen: 0
            )
        } else {
            Image(uiImage: image)
                .resizable()
                .brightness(model.effectiveBrightness)
                .contrast(model.effectiveContrast)
                .saturation(model.effectiveSaturation)
        }
    }

    @ViewBuilder
    private func clockOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            Spacer()
            HStack {
                // Clock (bottom-left)
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeString)
                        .font(.system(size: 48 * scale, weight: .light, design: .monospaced))
                    Text(dateString)
                        .font(.system(size: 20 * scale, weight: .regular))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func sensorOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            HStack {
                Spacer()
                // Sensors (top-right)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.sortedSensors) { sensor in
                        HStack(spacing: 4) {
                            if sensor.isUnavailable {
                                Text("\u{2757}")
                            }
                            Text(sensor.friendlyName + ":")
                            Text(sensor.isUnavailable ? (sensor.lastKnownState ?? "N/A") : sensor.state)
                            if !sensor.unitOfMeasurement.isEmpty {
                                Text(sensor.unitOfMeasurement)
                            }
                            Text(sensor.displayEmoji)
                        }
                        .font(.system(size: 16 * scale))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)
            }
            Spacer()
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: currentTime)
    }

    private var remoteRestorationStatus: String {
        guard let model = viewerModel else {
            return "Resolving viewer configuration"
        }
        if model.currentPost == nil {
            return model.isLoading ? "Loading first post" : "Waiting for server playback"
        }
        if let texture = model.currentTexture {
            return "Waiting for Metal frame (\(texture.width)x\(texture.height))"
        }
        if model.currentImage != nil {
            return "Waiting for image renderer"
        }
        return "Waiting for \(String(describing: model.currentMediaType))"
    }

    private func markContentPresented(renderer: String) {
        renderRecoveryTask?.cancel()
        renderRecoveryTask = nil
        renderRecoveryAttempt = 0
        if showRestorationPlaceholder {
            showRestorationPlaceholder = false
            AppLogger.windowState.info(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] content frame reported renderer=\(renderer, privacy: .public)"
            )
        }
        if !didArmInitialAutoHide {
            didArmInitialAutoHide = true
            controlsVisible = true
            resetAutoHideTimer()
        }
    }

    private func recoverStalledRenderer() {
        guard renderRecoveryAttempt < 3 else {
            AppLogger.windowState.error(
                "[Remote \(windowValue.id.uuidString, privacy: .public)] renderer recovery exhausted"
            )
            return
        }
        renderRecoveryAttempt += 1
        showRestorationPlaceholder = true
        controlsVisible = true
        autoHideTimer?.cancel()
        metalRendererGeneration += 1
        viewerModel?.refreshCurrentTextureForRenderRecovery()
        AppLogger.windowState.warning(
            "[Remote \(windowValue.id.uuidString, privacy: .public)] rebuilding Metal renderer attempt=\(self.renderRecoveryAttempt, privacy: .public)"
        )

        renderRecoveryTask?.cancel()
        renderRecoveryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, showRestorationPlaceholder else { return }
            await nudgeSceneForRenderRecovery()
        }
    }

    private func nudgeSceneForRenderRecovery() async {
        guard let scene = resolvedWindowScene else { return }
        let base = scene.effectiveGeometry.coordinateSpace.bounds.size
        guard Self.isPlausibleWindowSize(base) else { return }
        let nudged = CGSize(width: base.width + 1, height: base.height + 1)
        AppLogger.windowState.warning(
            "[Remote \(windowValue.id.uuidString, privacy: .public)] nudging scene for render recovery"
        )
        UIView.performWithoutAnimation {
            scene.requestGeometryUpdate(.Vision(size: nudged))
        }
        try? await Task.sleep(for: .milliseconds(150))
        UIView.performWithoutAnimation {
            scene.requestGeometryUpdate(.Vision(size: base))
        }
    }

    private func setupModel() {
        guard viewerModel == nil else { return }

        // Look up config from saved configs or the gallery slideshow config
        let config: RemoteViewerConfig
        if let saved = appModel.savedRemoteConfigs.first(where: { $0.id == windowValue.configId }) {
            config = saved
        } else if let gallery = appModel.gallerySlideshowConfig, gallery.id == windowValue.configId {
            config = gallery
        } else if let videoSlideshow = appModel.videoSlideshowConfig, videoSlideshow.id == windowValue.configId {
            config = videoSlideshow
        } else {
            AppLogger.remoteViewer.error("No config found for id \(windowValue.configId.uuidString, privacy: .public)")
            return
        }

        let model = RemoteViewerModel(config: config, windowId: windowValue.id)
        model.globalAdjustments = appModel.globalVisualAdjustments
        // Per-profile slideshow resolution caps fall back to the slideshow
        // defaults, which themselves default to 4096px.
        let resolved2D = config.maxImageResolution2D ?? appModel.slideshowMaxImageResolution2D
        let resolved3D = config.maxImageResolution3D ?? appModel.slideshowMaxImageResolution3D
        model.maxImageResolution = resolved2D
        model.maxImageResolution3D = resolved3D
        model.slideshow3DMode = config.slideshow3DMode
        model.updateWindowAspectRatio(windowSize)

        // Tag list state is per-window (created in RemoteViewerModel.init); the
        // current list is server-tracked. Seed the catalog from the last one
        // the app saw so the ornament has list names before the server
        // re-pushes `tagLists`, and mirror future pushes back for the next
        // window that opens.
        model.tagListManager?.tagLists = appModel.tagListCatalog
        model.tagListManager?.clampActiveIndex()
        model.onCatalogReceived = { [weak appModel] lists in
            appModel?.tagListCatalog = lists
        }
        model.modTagManager = appModel.modTagManager

        // Set up content provider based on mode
        if config.apiEndpoint.isEmpty {
            if let videoOverride = appModel.pendingVideoSlideshowSource,
               appModel.videoSlideshowConfig?.id == config.id {
                // Video slideshow mode: iterate over the video source/filter
                // snapshot from the launching video viewer.
                appModel.pendingVideoSlideshowSource = nil
                model.contentProvider = VideoSlideshowContentProvider(
                    videoSource: videoOverride.videoSource,
                    filter: videoOverride.filter
                )
            } else {
                // Gallery mode: prefer a transient override set by the launching
                // photo viewer (e.g. local-folder slideshow), otherwise fall back
                // to the app-wide image source and current filter.
                let source: any ImageSource
                let filter: ImageFilterCriteria?
                if let override = appModel.pendingGallerySlideshowSource {
                    source = override.imageSource
                    filter = override.filter
                    appModel.pendingGallerySlideshowSource = nil
                } else {
                    source = appModel.imageSource
                    filter = appModel.currentFilter
                }
                model.contentProvider = GalleryContentProvider(imageSource: source, filter: filter)
            }
        } else {
            // Remote API mode
            model.contentProvider = RemoteContentProvider(
                apiClient: model.apiClient,
                baseURL: config.apiEndpoint,
                accessToken: config.accessToken,
                deviceId: model.slideshowDeviceId
            )
        }

        // Wire up window callbacks
        model.onOpenAlertWindow = { [openWindow] text, bgColor, imageUrl in
            openWindow(id: "remote-alert", value: RemoteAlertWindowValue(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
        }
        model.onDismissAlertWindow = { [dismissWindow] in
            dismissWindow(id: "remote-alert")
        }

        model.onConfigChanged = { [appModel] updatedConfig in
            appModel.saveRemoteConfig(updatedConfig)
        }

        model.windowValue = windowValue
        self.viewerModel = model
        appModel.registerRemoteViewerWindow(configId: config.id, windowValue: windowValue)
        appModel.registerRemoteViewerModel(model)
        model.start()
    }

    private func startKenBurnsAnimation(model: RemoteViewerModel) {
        guard model.enableKenBurns else { return }

        resetKenBurns()

        // Then animate the zoom-in to the focus point
        let focus = model.focusPoint
        let targetScale: CGFloat = 1.3
        let offsetX = (focus.x - 0.5) * windowSize.width * 0.15
        let offsetY = (focus.y - 0.5) * windowSize.height * 0.15

        withAnimation(.easeInOut(duration: model.delay)) {
            kenBurnsScale = targetScale
            kenBurnsOffset = CGSize(width: -offsetX, height: -offsetY)
        }
    }

    private func resetKenBurns() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            kenBurnsScale = 1.0
            kenBurnsOffset = .zero
        }
    }

    /// Smallest geometry this window is allowed to occupy, and the floor below
    /// which a persisted size is treated as corrupt rather than restored.
    static let minimumWindowSize = CGSize(width: 480, height: 320)

    /// Whether a size is one the user could plausibly have resized to, as
    /// opposed to transient layout noise from a window the compositor hasn't
    /// placed yet. Guards both ends of the persist/restore round-trip.
    static func isPlausibleWindowSize(_ size: CGSize) -> Bool {
        size.width >= minimumWindowSize.width && size.height >= minimumWindowSize.height
            && size.width.isFinite && size.height.isFinite
    }

    /// Resolve the window scene hosting this viewer for geometry updates
    /// (restored-size apply, IPC calibration nudge). This is strictly THIS
    /// window's scene from the environment: the old foreground-active fallback
    /// could resolve to a *different* window and send it our resize, which is
    /// exactly the failure mode `VideoWindowView`'s aspect lock documents.
    private var resolvedWindowScene: UIWindowScene? {
        sceneDelegate?.windowScene
    }

    /// Apply the persisted custom window size (if any) on launch.
    ///
    /// `requestGeometryUpdate` is routinely ignored while visionOS is still
    /// mid-restoration (the photo viewer works around the same problem with
    /// its delayed size verifier), and at `onAppear` time this window's scene
    /// may not even be connected yet. So instead of a single fire-and-forget
    /// request, retry until the live geometry actually matches the restored
    /// size (within 5%), targeting only THIS window's scene via the
    /// SceneDelegate — never the foreground-active fallback, which can be a
    /// different window during cold launch. Write-back stays suppressed for
    /// the duration so the transient scene-default size isn't persisted.
    private func applyRestoredSizeIfNeeded() {
        // Suppress the write-back for the settle period on *every* restored
        // window, before the restored-size guard — not just ones that already
        // have a size persisted. The window that most needs protecting is the
        // one being restored for the first time: it has no archived size, so
        // arming suppression after the guard meant its transient restoration
        // geometry sailed straight into the archive. That is how a window gets
        // poisoned in the first place.
        if RestoredWindowTracker.isRestored(windowValue.id) {
            suppressSizeWriteback = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                suppressSizeWriteback = false
            }
        }

        // Prefer the scene-archive value; fall back to the UserDefaults store
        // (written in lockstep) in case the archive round-trip dropped it.
        guard let restored = windowValue.restoredSize?.cgSize
                ?? RestoredWindowTracker.windowSize(for: windowValue.id) else { return }
        // Reject a degenerate archived size instead of re-asserting it. An
        // already-poisoned archive heals here: we fall through to the scene
        // default rather than spending 5s forcing the window back to nothing.
        guard Self.isPlausibleWindowSize(restored) else {
            AppLogger.remoteViewer.warning("Ignoring implausible restored window size \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public) — falling back to the scene default")
            RestoredWindowTracker.clearWindowSize(for: windowValue.id)
            return
        }
        suppressSizeWriteback = true
        let source = windowValue.restoredSize != nil ? "scene archive" : "defaults fallback"
        AppLogger.remoteViewer.info("Applying restored window size \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public) (\(source, privacy: .public))")
        Task { @MainActor in
            defer { suppressSizeWriteback = false }
            for attempt in 0..<8 {
                if let windowScene = sceneDelegate?.windowScene {
                    UIView.performWithoutAnimation {
                        windowScene.requestGeometryUpdate(.Vision(size: restored))
                    }
                }
                // Give the OS time to resolve (or ignore) the request, then
                // check the live size reported by the GeometryReader. The
                // geo size is content size (insets differ from the scene
                // size), so compare with a tolerance.
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 700))
                let current = windowSize
                if current.width > 2, current.height > 2,
                   abs(current.width - restored.width) / restored.width < 0.05,
                   abs(current.height - restored.height) / restored.height < 0.05 {
                    return
                }
            }
            AppLogger.remoteViewer.warning("Restored window size did not apply after retries (wanted \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public), have \(Int(windowSize.width), privacy: .public)x\(Int(windowSize.height), privacy: .public))")
        }
    }

    /// Debounce a write-back of the resolved window size into the Codable window
    /// value so visionOS persists it for the next cold relaunch.
    private func scheduleSizeWriteback(_ size: CGSize) {
        guard let onSizeSettled else { return }
        // The old floor here was `> 2`, which happily persisted the transient
        // geometry a not-yet-placed window reports during restoration. That
        // value then got re-asserted on every subsequent launch, so the window
        // came back invisible until its scene session was destroyed ("Close All
        // Windows"). Only persist a size a user could plausibly have chosen.
        guard !suppressSizeWriteback, Self.isPlausibleWindowSize(size) else { return }
        sizeWritebackTask?.cancel()
        sizeWritebackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onSizeSettled(size)
            // UserDefaults backup in case the scene archive drops the value
            RestoredWindowTracker.setWindowSize(size, for: windowValue.id)
        }
    }

    private func nudgeWindowSizeForCalibration() {
        guard let windowScene = resolvedWindowScene else { return }
        // Nudge from the *scene's* own geometry, not the GeometryReader's
        // content size. Feeding a content size back in as a scene size shrinks
        // the window by the chrome insets on every crossfade — a ratchet that
        // walks a 3D slideshow window down to nothing over a long session, and
        // whose end state the size write-back then persists.
        let base = windowScene.coordinateSpace.bounds.size
        guard Self.isPlausibleWindowSize(base) else { return }
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

    private func resetAutoHideTimer() {
        autoHideTimer?.cancel()
        guard appModel.autoHideDelay > 0 else { return }
        autoHideTimer = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}
