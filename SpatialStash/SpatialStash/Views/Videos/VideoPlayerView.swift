/*
 Spatial Stash - Video Player View

 Routes between 2D web player and stereoscopic 3D player based on video type.
 */

import SwiftUI

struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel

    /// Override for stereoscopic mode: nil = auto-detect, true = force 3D, false = force 2D
    @State private var forceStereoscopic: Bool? = nil

    var body: some View {
        Group {
            if let video = appModel.selectedVideo {
                if shouldUseStereoscopicPlayer(for: video) {
                    // Use stereoscopic player for 3D content
                    StereoscopicVideoView(video: video)
                        .id(video.id)
                } else {
                    // Use standard web player for 2D content
                    WebVideoPlayerView(
                        videoURL: video.streamURL,
                        apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(video.id)
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
            forceStereoscopic = nil
        }
        .onChange(of: appModel.selectedVideo?.id) {
            // Reset UI visibility, timer, and stereoscopic override when video changes
            appModel.isUIHidden = false
            appModel.startAutoHideTimer()
            forceStereoscopic = nil
        }
    }

    /// Determine whether to use the stereoscopic player for a video
    private func shouldUseStereoscopicPlayer(for video: GalleryVideo) -> Bool {
        // Check manual override first
        if let force = forceStereoscopic {
            return force
        }
        // Otherwise use auto-detection from tags
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

    /// Toggle or set stereoscopic mode override
    func setStereoscopicOverride(_ value: Bool?) {
        forceStereoscopic = value
    }
}
