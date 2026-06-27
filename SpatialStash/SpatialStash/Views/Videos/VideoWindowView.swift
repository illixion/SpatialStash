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

    /// Extra bottom padding to prevent the ornament from overlapping video content
    private let ornamentBottomPadding: CGFloat = 60

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
                    } else {
                        WebVideoPlayerView(
                            videoURL: video.streamURL,
                            apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey,
                            // Native Safari controls are off; our SwiftUI
                            // control bar drives playback via the JS bridge.
                            showControls: false,
                            isRoomActive: windowModel.isInActiveRoom,
                            onVideoSizeKnown: { size in
                                lockWindowToVideoAspectRatio(videoSize: size)
                            },
                            loopController: windowModel.loopController,
                            playbackModel: windowModel
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(video.id)_2d")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(x: windowModel.isFlipped ? -1 : 1, y: 1)
                .brightness(windowModel.effectiveVideoAdjustments.brightness)
                .contrast(windowModel.effectiveVideoAdjustments.contrast)
                .saturation(windowModel.effectiveVideoAdjustments.saturation)
                .opacity(windowModel.effectiveVideoAdjustments.opacity)
                .overlay {
                    // Transparent tap target that only appears when UI is hidden
                    if windowModel.isUIHidden {
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

            // Custom playback controls (2D web player only)
            if !appModel.allWindowsHidden, !windowModel.shouldUse3DMode, !windowModel.isUIHidden {
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
            onGalleryButtonTap: {
                appModel.showMainWindow(openWindow: openWindow)
            },
            onPopOut: windowValue.wasPushed ? {
                let newValue = VideoWindowValue(
                    video: windowModel.video,
                    stereoscopicOverride: windowModel.stereoscopicOverride,
                    video3DSettings: windowModel.video3DSettings
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
        let videoWidth: CGFloat = 1200
        let videoHeight = videoWidth / videoAspectRatio
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
