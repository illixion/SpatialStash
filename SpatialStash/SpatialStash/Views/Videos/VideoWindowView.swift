/*
 Spatial Stash - Video Window View

 Standalone pop-out window for video playback.
 Shows the same video player as the main window with a minimal ornament
 containing only a gallery button that auto-hides after the configured delay.
 */

import os
import SwiftUI

struct VideoWindowView: View {
    let windowValue: VideoWindowValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var isUIHidden = false
    @State private var isWindowControlsHidden = false
    @State private var autoHideTask: Task<Void, Never>?
    @State private var windowControlsHideTask: Task<Void, Never>?
    @State private var stereoscopicOverride: Bool?
    @State private var video3DSettings: Video3DSettings?
    @State private var isVideoFlipped: Bool = false

    // MARK: - Room Activity / Memory Management

    /// Whether this window is in the user's current room
    @State private var isInActiveRoom: Bool = true

    /// Whether the video has been unloaded to free memory (WKWebView removed)
    @State private var isVideoUnloaded: Bool = false

    /// Task that fires after the inactivity timeout to unload the video
    @State private var scenePhaseIdleTask: Task<Void, Never>?

    /// How long a video window must remain in an inactive room before unloading
    private static let scenePhaseIdleTimeout: TimeInterval = 5 * 60 // 5 minutes

    /// Extra bottom padding to prevent the ornament from overlapping video content
    private let ornamentBottomPadding: CGFloat = 60

    private var video: GalleryVideo { windowValue.video }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isVideoUnloaded {
                    // Video unloaded to save memory while in inactive room
                    unloadedPlaceholder
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
            .scaleEffect(x: isVideoFlipped ? -1 : 1, y: 1)
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
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isVideoFlipped.toggle()
                        }
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.title3)
                            .padding(6)
                            .background(isVideoFlipped ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.borderless)
                    .help("Flip Video")

                    Button {
                        appModel.showMainWindow(openWindow: openWindow)
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("Show Gallery")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
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
        }
        .onDisappear {
            cancelAutoHideTimer()
            scenePhaseIdleTask?.cancel()
            scenePhaseIdleTask = nil
            restoreWindowResizing()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
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

            // Cancel any pending unload
            scenePhaseIdleTask?.cancel()
            scenePhaseIdleTask = nil

            // Reload video if it was unloaded while in another room
            if isVideoUnloaded {
                AppLogger.videoWindow.info("[\(videoDisplayName, privacy: .public)] Restoring video after room re-entry")
                isVideoUnloaded = false
            }
        } else if oldPhase == .active && (newPhase == .inactive || newPhase == .background) {
            isInActiveRoom = false

            // Schedule video unload after timeout to free memory
            scheduleVideoUnload()
        }
    }

    private func scheduleVideoUnload() {
        scenePhaseIdleTask?.cancel()
        scenePhaseIdleTask = Task {
            do {
                try await Task.sleep(for: .seconds(Self.scenePhaseIdleTimeout))
            } catch {
                return // Cancelled — window became active again
            }

            guard !Task.isCancelled, !isVideoUnloaded else { return }

            AppLogger.videoWindow.info("[\(videoDisplayName, privacy: .public)] Unloading video after scene-phase timeout")
            isVideoUnloaded = true
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

    private var unloadedPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.badge.ellipsis")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Video paused — not in current room")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
