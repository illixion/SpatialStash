/*
 Spatial Stash - Video Player View

 Routes between 2D web player and stereoscopic 3D player based on video type.
 Uses AppModel state for 3D mode toggle (controlled via VideoOrnamentsView).
 */

import SwiftUI

struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
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
                    // Use standard web player for 2D content
                    WebVideoPlayerView(
                        videoURL: video.streamURL,
                        apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id("\(video.id)_2d")
                }
            } else {
                noVideoSelectedView
            }
        }
        .onAppear {
            appModel.startAutoHideTimer()
        }
        .onDisappear {
            appModel.cancelAutoHideTimer()
        }
        .onChange(of: appModel.selectedVideo?.id) {
            // Reset UI visibility and timer when video changes
            appModel.isUIHidden = false
            appModel.startAutoHideTimer()
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
