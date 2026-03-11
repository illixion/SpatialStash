/*
 Spatial Stash - Video Window View

 Standalone pop-out window for video playback.
 Shows the same video player as the main window with a minimal ornament
 containing only a gallery button that auto-hides after the configured delay.
 */

import SwiftUI

struct VideoWindowView: View {
    let windowValue: VideoWindowValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @State private var isUIHidden = false
    @State private var isWindowControlsHidden = false
    @State private var autoHideTask: Task<Void, Never>?
    @State private var windowControlsHideTask: Task<Void, Never>?
    @State private var stereoscopicOverride: Bool?
    @State private var video3DSettings: Video3DSettings?

    /// Extra bottom padding to prevent the ornament from overlapping video content
    private let ornamentBottomPadding: CGFloat = 60

    private var video: GalleryVideo { windowValue.video }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if shouldUseStereoscopicPlayer {
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
                        showControls: !isUIHidden
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("\(video.id)_2d")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        appModel.showMainWindowIfNeeded(openWindow: openWindow)
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
            lockWindowToVideoAspectRatio()
        }
        .onDisappear {
            cancelAutoHideTimer()
            restoreWindowResizing()
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

    private func lockWindowToVideoAspectRatio() {
        guard let sourceWidth = video.sourceWidth, sourceWidth > 0,
              let sourceHeight = video.sourceHeight, sourceHeight > 0,
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }

        let videoAspectRatio = CGFloat(sourceWidth) / CGFloat(sourceHeight)
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
}
