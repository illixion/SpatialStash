/*
 Spatial Stash - Video Window View

 Window view for video playback.
 Handles two modes:
 - Pushed (wasPushed=true): opened via pushWindow from gallery, dismiss returns to gallery.
   Shows full ornament with navigation, rating, share, adjustments, flip, pop-out.
 - Standalone (wasPushed=false): opened via openWindow as independent pop-out window.
   Shows same ornament as pushed, but without pop-out button (matching photo viewer pattern).
 */

import os
import SwiftUI

struct VideoWindowView: View {
    let windowValue: VideoWindowValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var isUIHidden = false
    @State private var isWindowControlsHidden = false
    @State private var autoHideTask: Task<Void, Never>?
    @State private var windowControlsHideTask: Task<Void, Never>?
    @State private var stereoscopicOverride: Bool?
    @State private var video3DSettings: Video3DSettings?
    /// Prevents onDisappear from clearing selectedVideo when popping out to a standalone window
    @State private var isPoppingOut: Bool = false

    // MARK: - Room Activity / Memory Management

    /// Whether this window is in the user's current room
    @State private var isInActiveRoom: Bool = true

    /// Extra bottom padding to prevent the ornament from overlapping video content
    private let ornamentBottomPadding: CGFloat = 60

    /// For pushed windows, follow AppModel.selectedVideo so prev/next navigation works.
    /// For standalone pop-outs, use the snapshot from windowValue.
    private var video: GalleryVideo {
        if windowValue.wasPushed, let selected = appModel.selectedVideo {
            return selected
        }
        return windowValue.video
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if appModel.allWindowsHidden {
                    Color.clear
                } else if shouldUseStereoscopicPlayer {
                    StereoscopicVideoView(
                        video: video,
                        initialSettings: video3DSettings,
                        onRevertTo2D: {
                            stereoscopicOverride = false
                        },
                        onSettingsChanged: { newSettings in
                            video3DSettings = newSettings
                        }
                    )
                    .id("\(video.id)_3d")
                } else {
                    WebVideoPlayerView(
                        videoURL: video.streamURL,
                        apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey,
                        showControls: !isUIHidden,
                        isRoomActive: isInActiveRoom,
                        onVideoSizeKnown: { size in
                            lockWindowToVideoAspectRatio(videoSize: size)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("\(video.id)_2d")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(x: appModel.isVideoFlipped ? -1 : 1, y: 1)
            .brightness(effectiveVideoAdjustments.brightness)
            .contrast(effectiveVideoAdjustments.contrast)
            .saturation(effectiveVideoAdjustments.saturation)
            .opacity(effectiveVideoAdjustments.opacity)
            .overlay {
                // Transparent tap target that only appears when UI is hidden
                if isUIHidden {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            toggleUIVisibility()
                        }
                }
            }

            Spacer()
                .frame(height: ornamentBottomPadding)
        }
        .persistentSystemOverlays(isWindowControlsHidden ? .hidden : .visible)
        .ornament(
            visibility: isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                videoOrnament
            }
        )
        .sheet(isPresented: Binding(
            get: { appModel.showVideo3DSettingsSheet },
            set: { appModel.showVideo3DSettingsSheet = $0 }
        )) {
            Video3DSettingsSheet(
                initialSettings: video3DSettings,
                onApply: { settings in
                    Task {
                        await Video3DSettingsTracker.shared.saveSettings(
                            videoId: video.stashId,
                            settings: settings
                        )
                    }
                    video3DSettings = settings
                    stereoscopicOverride = true
                },
                onCancel: nil
            )
        }
        .onAppear {
            stereoscopicOverride = windowValue.stereoscopicOverride
            video3DSettings = windowValue.video3DSettings
            startAutoHideTimer()
            // Set AppModel video state so VideoOrnamentsView works for both contexts
            appModel.selectVideoForDetail(video)
        }
        .onDisappear {
            cancelAutoHideTimer()
            restoreWindowResizing()
            // Don't clear selectedVideo when popping out — the standalone window needs it
            if !isPoppingOut {
                appModel.dismissVideoDetail()
            }
        }
        .onChange(of: appModel.selectedVideo) { _, newVideo in
            // When prev/next navigation changes the selected video, reset per-video state
            if windowValue.wasPushed, newVideo != nil {
                stereoscopicOverride = nil
                video3DSettings = nil
                appModel.isVideoFlipped = false
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Visual Adjustments

    /// Effective adjustments: use per-video session if modified, otherwise global
    private var effectiveVideoAdjustments: VisualAdjustments {
        appModel.videoVisualAdjustments.isModified ? appModel.videoVisualAdjustments : appModel.globalVisualAdjustments
    }

    // MARK: - Ornament

    /// Unified ornament for both pushed and standalone windows.
    /// Only the pop-out button differs (hidden for standalone), matching photo viewer pattern.
    private var videoOrnament: some View {
        VideoOrnamentsView(
            videoCount: appModel.galleryVideos.count,
            video: video,
            wasPushed: windowValue.wasPushed,
            onGalleryButtonTap: {
                appModel.showMainWindow(openWindow: openWindow)
            },
            onPopOut: windowValue.wasPushed ? {
                isPoppingOut = true
                let windowValue = VideoWindowValue(
                    video: video,
                    stereoscopicOverride: stereoscopicOverride,
                    video3DSettings: video3DSettings
                )
                openWindow(id: "video-detail", value: windowValue)
                dismissWindow()
            } : nil
        )
    }

    // MARK: - Stereoscopic Mode

    private var shouldUseStereoscopicPlayer: Bool {
        if stereoscopicOverride == false { return false }
        if stereoscopicOverride == true || video3DSettings != nil { return true }
        return video.isStereoscopic
    }

    // MARK: - Auto-Hide

    private func startAutoHideTimer() {
        cancelAutoHideTimer()
        guard appModel.autoHideDelay > 0 else { return }

        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            if !Task.isCancelled {
                isUIHidden = true
                scheduleWindowControlsHiding()
            }
        }
    }

    private func scheduleWindowControlsHiding() {
        windowControlsHideTask?.cancel()
        windowControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                isWindowControlsHidden = true
            }
        }
    }

    private func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
        windowControlsHideTask?.cancel()
        windowControlsHideTask = nil
        isWindowControlsHidden = false
    }

    private func toggleUIVisibility() {
        isUIHidden.toggle()
        isWindowControlsHidden = false
        if !isUIHidden {
            startAutoHideTimer()
        }
    }

    // MARK: - Window Aspect Ratio

    /// Lock the window's resize aspect ratio to the video's native dimensions
    /// (reported by the HTML video element's loadedmetadata event).
    private func lockWindowToVideoAspectRatio(videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0,
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }

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
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    // MARK: - Scene Phase / Room Activity

    private var videoDisplayName: String {
        video.title ?? video.streamURL.lastPathComponent
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        AppLogger.videoWindow.info(
            "[\(videoDisplayName, privacy: .public)] scenePhase: \(phaseLabel(oldPhase), privacy: .public) → \(phaseLabel(newPhase), privacy: .public)"
        )

        if newPhase == .active {
            isInActiveRoom = true
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false
        }
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
