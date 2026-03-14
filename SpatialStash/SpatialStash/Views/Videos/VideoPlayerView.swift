/*
 Spatial Stash - Video Player View

 Routes between 2D web player and stereoscopic 3D player based on video type.
 Uses AppModel state for 3D mode toggle (controlled via VideoOrnamentsView).
 Locks window resize aspect ratio to the video's native dimensions with bottom
 padding to prevent the ornament from overlapping video content.
 */

import SwiftUI

struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel

    /// Extra bottom padding (in points) to prevent the ornament from overlapping video content
    private let ornamentBottomPadding: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let video = appModel.selectedVideo {
                    if shouldUseStereoscopicPlayer(for: video) {
                        // Use stereoscopic player for 3D content
                        StereoscopicVideoView(
                            video: video,
                            initialSettings: appModel.video3DSettings,
                            onRevertTo2D: {
                                appModel.videoStereoscopicOverride = false
                            },
                            onSettingsChanged: { newSettings in
                                appModel.video3DSettings = newSettings
                            }
                        )
                        .id("\(video.id)_3d")
                    } else {
                        WebVideoPlayerView(
                            videoURL: video.streamURL,
                            apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey,
                            showControls: !appModel.isUIHidden
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("\(video.id)_2d")
                    }
                } else {
                    noVideoSelectedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(x: appModel.isVideoFlipped ? -1 : 1, y: 1)

            // Bottom spacer to keep ornament below video content
            Spacer()
                .frame(height: ornamentBottomPadding)
        }
        .onAppear {
            appModel.startAutoHideTimer()
            lockWindowToVideoAspectRatio()
        }
        .onDisappear {
            appModel.cancelAutoHideTimer()
            restoreWindowResizing()
        }
        .onChange(of: appModel.selectedVideo?.id) {
            // Reset UI visibility and timer when video changes
            appModel.isUIHidden = false
            appModel.startAutoHideTimer()
            lockWindowToVideoAspectRatio()
        }
        .sheet(isPresented: Binding(
            get: { appModel.showVideo3DSettingsSheet },
            set: { appModel.showVideo3DSettingsSheet = $0 }
        )) {
            if let video = appModel.selectedVideo {
                Video3DSettingsSheet(
                    initialSettings: appModel.video3DSettings,
                    onApply: { settings in
                        // Save settings and switch to 3D
                        Task {
                            await Video3DSettingsTracker.shared.saveSettings(
                                videoId: video.stashId,
                                settings: settings
                            )
                        }
                        appModel.video3DSettings = settings
                        appModel.videoStereoscopicOverride = true
                    },
                    onCancel: nil
                )
            }
        }
    }

    // MARK: - Window Aspect Ratio Locking

    /// Lock the main window's resize aspect ratio to the selected video's dimensions,
    /// accounting for bottom padding that keeps the ornament from overlapping.
    private func lockWindowToVideoAspectRatio() {
        guard let video = appModel.selectedVideo,
              let sourceWidth = video.sourceWidth, sourceWidth > 0,
              let sourceHeight = video.sourceHeight, sourceHeight > 0,
              let windowScene = mainWindowScene else { return }

        let videoAspectRatio = CGFloat(sourceWidth) / CGFloat(sourceHeight)

        // Calculate a window size that fits the video at its aspect ratio
        // plus bottom padding for the ornament
        let currentSize = appModel.mainWindowSize
        let videoWidth = currentSize.width
        let videoHeight = videoWidth / videoAspectRatio
        let totalHeight = videoHeight + ornamentBottomPadding
        let windowSize = CGSize(width: videoWidth, height: totalHeight)

        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: windowSize, resizingRestrictions: .uniform))
        }
    }

    /// Restore freeform window resizing when leaving the video player
    private func restoreWindowResizing() {
        guard let windowScene = mainWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    private var mainWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// Determine whether to use the stereoscopic player for a video
    private func shouldUseStereoscopicPlayer(for video: GalleryVideo) -> Bool {
        // Explicitly set to 2D
        if appModel.videoStereoscopicOverride == false {
            return false
        }
        // Explicitly set to 3D or has custom settings
        if appModel.videoStereoscopicOverride == true || appModel.video3DSettings != nil {
            return true
        }
        // Auto-detect from video tags
        return video.isStereoscopic
    }

    private var noVideoSelectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.slash")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("No video selected")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
