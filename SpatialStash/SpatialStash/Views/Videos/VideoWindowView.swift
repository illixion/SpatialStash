/*
 Spatial Stash - Video Window View

 Window view for video playback.
 Handles two modes:
 - Pushed (wasPushed=true): opened via pushWindow from gallery, dismiss returns to gallery.
   Shows full ornament with navigation, rating, share, adjustments, flip, pop-out.
 - Standalone (wasPushed=false): opened via openWindow as independent pop-out window.
   Shows same ornament as pushed, but without pop-out button (matching photo viewer pattern).

 All per-window state lives in `VideoWindowModel` (created with @State here, like
 PhotoWindowModel), so multiple video windows are fully independent.
 */

import os
import SwiftUI

struct VideoWindowView: View {
    let windowValue: VideoWindowValue
    @State private var windowModel: VideoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    /// THIS window's scene (used for aspect-ratio locking). Reading it from the
    /// environment avoids the multi-window bug of resizing an arbitrary
    /// foreground-active scene.
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    /// Reserved space below the video so the bottom ornament (which floats at the
    /// window's bottom edge) doesn't overlap the video. Larger for fake-3D, whose
    /// two-row ornament is taller and needs more clearance from the video plane.
    private var ornamentBottomPadding: CGFloat {
        windowModel.shouldUsePseudo3D ? 120 : 60
    }

    /// Depth offset (points, toward the viewer) applied to the fake-3D chrome.
    /// Kept at 0 so the ornament stays coplanar with the video AND the visionOS
    /// window controls — all three on the window's front glass. The video plane
    /// already sits on that glass because `Pseudo3DVideoPlayerView` pins it with
    /// `.frame(depth: 0, alignment: .front)`; an earlier 20cm forward push
    /// (added before that alignment fix) floated the whole ornament out in front
    /// of that plane, which is what made the chrome "sit apart" from the video
    /// and cast its silhouette over the window controls below. Tunable: nudge a
    /// few points forward only if residual stereo pop-out makes the chrome read
    /// as slightly behind near subjects.
    private let pseudo3DChromeZOffset: CGFloat = 0

    /// Upward lift (points) for the taller two-row fake-3D ornament so its lower
    /// transport row keeps clear of the visionOS window controls below the
    /// window. With the chrome now coplanar (no forward push) this is pure bottom
    /// padding rather than parallax compensation. visionOS points map to real cm
    /// at ~10 points/cm, so 50 ≈ 5cm.
    private let pseudo3DChromeBottomLift: CGFloat = 50

    init(windowValue: VideoWindowValue, appModel: AppModel) {
        self.windowValue = windowValue
        _windowModel = State(initialValue: VideoWindowModel(windowValue: windowValue, appModel: appModel))
    }

    private var video: GalleryVideo { windowModel.video }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Group {
                    if appModel.allWindowsHidden {
                        Color.clear
                    } else if windowModel.shouldUse3DMode {
                        StereoscopicVideoView(
                            video: video,
                            windowModel: windowModel,
                            initialSettings: windowModel.video3DSettings,
                            onRevertTo2D: {
                                windowModel.stereoscopicOverride = false
                            },
                            onSettingsChanged: { newSettings in
                                windowModel.video3DSettings = newSettings
                            }
                        )
                        .id("\(video.id)_3d")
                    } else if windowModel.shouldUsePseudo3D {
                        Pseudo3DVideoPlayerView(
                            videoURL: windowModel.authenticatedStreamURL,
                            isRoomActive: windowModel.isInActiveRoom,
                            // Recede the video (in-scene) while a menu/popover is
                            // open so it doesn't occlude the presented chrome.
                            chromeOpen: windowModel.isChromeModalOpen,
                            onVideoSizeKnown: { size in
                                lockWindowToVideoAspectRatio(videoSize: size)
                            },
                            visualAdjustments: windowModel.effectiveVideoAdjustments,
                            settings: windowModel.effectivePseudo3DSettings,
                            isFlipped: windowModel.isFlipped,
                            loopController: windowModel.loopController,
                            playbackModel: windowModel,
                            onPlaybackError: {
                                // Fall back to the flat native player if the
                                // stereo pipeline can't decode this source.
                                windowModel.disablePseudo3D()
                            },
                            // A 2D transparent overlay can't catch gaze over a
                            // RealityView, so the tap-to-toggle lives inside it as
                            // a RealityKit tap target instead.
                            onToggleUI: {
                                windowModel.toggleUIVisibility()
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(video.id)_pseudo3d")
                    } else {
                        switch windowModel.playbackRenderer {
                        case .resolving:
                            ProgressView("Loading video...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .id("\(video.id)_resolving")

                        case .nativeMetal:
                            NativeMetalVideoPlayerView(
                                videoURL: windowModel.authenticatedStreamURL,
                                isRoomActive: windowModel.isInActiveRoom,
                                onVideoSizeKnown: { size in
                                    lockWindowToVideoAspectRatio(videoSize: size)
                                },
                                visualAdjustments: windowModel.effectiveVideoAdjustments,
                                loopController: windowModel.loopController,
                                playbackModel: windowModel,
                                onPlaybackError: {
                                    windowModel.forceWebKitPlayback()
                                }
                            )
                            // Preserve aspect (the Metal renderer stretches the
                            // texture to fill its view). If the window can't match
                            // the video's aspect, this letterboxes rather than
                            // stretching — the fix for tall videos appearing wide.
                            .aspectRatio(windowModel.videoAspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id("\(video.id)_native")

                        case .webKit:
                            WebVideoPlayerView(
                                videoURL: windowModel.authenticatedStreamURL,
                                fallbackVideoURL: windowModel.authenticatedFallbackStreamURL,
                                apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey,
                                // Native Safari controls are off; our SwiftUI
                                // control bar drives playback via the JS bridge.
                                showControls: false,
                                isRoomActive: windowModel.isInActiveRoom,
                                onVideoSizeKnown: { size in
                                    lockWindowToVideoAspectRatio(videoSize: size)
                                },
                                visualAdjustments: windowModel.effectiveVideoAdjustments,
                                loopController: windowModel.loopController,
                                playbackModel: windowModel
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id("\(video.id)_web")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fake-3D handles the mirror inside the warp shader; mirroring
                // the RealityView container would invert the stereo pair too.
                .scaleEffect(x: (windowModel.isFlipped && !windowModel.shouldUsePseudo3D) ? -1 : 1, y: 1)
                .brightness(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.brightness : 0)
                .contrast(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.contrast : 1)
                .saturation(windowModel.shouldUse3DMode ? windowModel.effectiveVideoAdjustments.saturation : 1)
                .opacity(
                    windowModel.shouldUse3DMode || windowModel.playbackRenderer == .nativeMetal
                        ? windowModel.effectiveVideoAdjustments.opacity
                        : 1
                )
                .overlay {
                    // Transparent tap target over the video surface. Keep it
                    // present when chrome is visible too so tapping the video
                    // toggles controls both ways; transport controls are in a
                    // higher ZStack layer and still receive their own input.
                    // The pseudo-3D RealityView can't be toggled by a 2D overlay
                    // (gaze targets the 3D plane), so it carries its own tap
                    // target via onToggleUI instead.
                    if !appModel.allWindowsHidden, !windowModel.shouldUsePseudo3D {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                windowModel.toggleUIVisibility()
                            }
                    }
                }

                Spacer()
                    .frame(height: ornamentBottomPadding)
            }

            // Toast notification (A-B loop feedback)
            if let toast = windowModel.loopController.toastMessage {
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
                                    .fill(windowModel.loopController.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7))
                            )
                        Spacer()
                    }
                    .padding(.bottom, ornamentBottomPadding + 96)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut, value: windowModel.loopController.toastMessage)
            }

            // Custom playback controls (2D players only). In fake-3D the
            // transport is folded into the ornament (showTransport) so it shares
            // the chrome's depth instead of floating at the window plane.
            if !appModel.allWindowsHidden, !windowModel.shouldUse3DMode,
               !windowModel.shouldUsePseudo3D, !windowModel.isUIHidden {
                VStack {
                    Spacer()
                    VideoControlBar(windowModel: windowModel)
                        .padding(.horizontal, 24)
                        .padding(.bottom, ornamentBottomPadding + 12)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: windowModel.isUIHidden)
        .persistentSystemOverlays(windowModel.isWindowControlsHidden ? .hidden : .visible)
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                videoOrnament
                    // Lift the taller two-row ornament so its transport row
                    // clears the visionOS window controls beneath the window.
                    .padding(.bottom, windowModel.shouldUsePseudo3D ? pseudo3DChromeBottomLift : 0)
                    // Keep the fake-3D chrome coplanar with the video (which is
                    // pinned to the front glass via .frame(depth:0,.front)) and
                    // the window controls — see pseudo3DChromeZOffset. 0 = no
                    // forward push; the constant stays for on-device fine-tuning.
                    .offset(z: windowModel.shouldUsePseudo3D ? pseudo3DChromeZOffset : 0)
            }
        )
        .sheet(isPresented: $windowModel.showVideo3DSettingsSheet) {
            Video3DSettingsSheet(
                initialSettings: windowModel.video3DSettings,
                onApply: { settings in
                    Task {
                        await Video3DSettingsTracker.shared.saveSettings(
                            videoId: video.stashId,
                            settings: settings
                        )
                    }
                    windowModel.video3DSettings = settings
                    windowModel.stereoscopicOverride = true
                },
                onCancel: nil
            )
        }
        .onAppear {
            // Wall-snapped pop-outs restored by visionOS after a reboot come
            // back with the same windowValue UUID. Repeat appearances of the
            // same UUID are treated as system-restored — start with ornaments
            // hidden instead of arming the reveal timer.
            if !windowValue.wasPushed, RestoredWindowTracker.isRestored(windowValue.id) {
                windowModel.isRestoredPopOut = true
                windowModel.isUIHidden = true
                windowModel.isWindowControlsHidden = true
            } else {
                if !windowValue.wasPushed {
                    RestoredWindowTracker.markSeen(windowValue.id)
                }
                windowModel.startAutoHideTimer()
            }
            windowModel.start()
        }
        .onDisappear {
            windowModel.cleanup()
            restoreWindowResizing()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            AppLogger.videoWindow.info(
                "[\(windowModel.videoDisplayName, privacy: .public)] scenePhase: \(phaseLabel(oldPhase), privacy: .public) → \(phaseLabel(newPhase), privacy: .public)"
            )
            windowModel.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Ornament

    /// Unified ornament for both pushed and standalone windows.
    /// Only the pop-out button differs (hidden for standalone), matching photo viewer pattern.
    private var videoOrnament: some View {
        VideoOrnamentsView(
            windowModel: windowModel,
            showTransport: windowModel.shouldUsePseudo3D,
            onGalleryButtonTap: {
                appModel.showMainWindow(openWindow: openWindow)
            },
            onPopOut: windowValue.wasPushed ? {
                let newValue = VideoWindowValue(
                    video: windowModel.video,
                    // Preserve a static (Local) navigation list across pop-out.
                    galleryVideos: windowModel.usesStaticGalleryList ? windowModel.galleryVideos : nil,
                    stereoscopicOverride: windowModel.stereoscopicOverride,
                    video3DSettings: windowModel.video3DSettings,
                    pseudo3DEnabled: windowModel.pseudo3DEnabled,
                    pseudo3DSettings: windowModel.pseudo3DSettings
                )
                openWindow(id: "video-detail", value: newValue)
                dismissWindow()
            } : nil
        )
    }

    // MARK: - Window Aspect Ratio

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate { return sceneDelegate.windowScene }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// Lock the window's resize aspect ratio to the video's native dimensions
    /// (reported by the HTML video element's loadedmetadata event).
    private func lockWindowToVideoAspectRatio(videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0,
              let windowScene = resolvedWindowScene else { return }

        let videoAspectRatio = videoSize.width / videoSize.height
        windowModel.videoAspectRatio = videoAspectRatio

        // Fit the video area into a bounded box, capping the LONGER side. Fixing
        // width at 1200 meant a tall (e.g. 1080x1920) video requested a ~2200pt
        // window; visionOS clamps that height, leaving a window wider than the
        // video — and the Metal renderer stretches the frame to fill it. Capping
        // the longer side keeps the requested window within limits and correctly
        // proportioned for portrait, square, and landscape alike.
        let maxVideoDimension: CGFloat = 1200
        let videoWidth: CGFloat
        let videoHeight: CGFloat
        if videoAspectRatio >= 1 {
            videoWidth = maxVideoDimension
            videoHeight = maxVideoDimension / videoAspectRatio
        } else {
            videoHeight = maxVideoDimension
            videoWidth = maxVideoDimension * videoAspectRatio
        }
        let totalHeight = videoHeight + ornamentBottomPadding
        let windowSize = CGSize(width: videoWidth, height: totalHeight)

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: windowSize, resizingRestrictions: .uniform))
        }
    }

    private func restoreWindowResizing() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    private func phaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
