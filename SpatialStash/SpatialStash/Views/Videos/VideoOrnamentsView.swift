/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    let videoCount: Int

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                // Back to Gallery button
                Button {
                    appModel.dismissVideoDetail()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Videos")
                    }
                }

                Divider()
                    .frame(height: 24)

                // Previous video
                Button {
                    appModel.previousVideo()
                } label: {
                    Image(systemName: "arrow.left.circle")
                }
                .disabled(!appModel.hasPreviousVideo)

                // Video counter
                if appModel.currentVideoPosition > 0 {
                    Text("\(appModel.currentVideoPosition) / \(videoCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 60)
                }

                // Next video
                Button {
                    appModel.nextVideo()
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .disabled(!appModel.hasNextVideo)

                // View mode toggle (2D/3D for all videos)
                if let video = appModel.selectedVideo {
                    Divider()
                        .frame(height: 24)

                    viewModeMenu(for: video)
                }

                // Video title if available
                if let title = appModel.selectedVideo?.title, !title.isEmpty {
                    Divider()
                        .frame(height: 24)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding()
        }
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func viewModeMenu(for video: GalleryVideo) -> some View {
        Menu {
            // 2D Mode option
            Button {
                appModel.videoStereoscopicOverride = false
            } label: {
                HStack {
                    Text("2D")
                    if !shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // 3D Mode option
            Button {
                enable3DMode(for: video)
            } label: {
                HStack {
                    Text("3D")
                    if shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            // Edit 3D Settings (only show when in 3D mode)
            if shouldUse3DMode {
                Divider()

                Button {
                    appModel.showVideo3DSettingsSheet = true
                } label: {
                    Label("Edit 3D Settings", systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentModeIcon)
                Text(currentModeLabel)
                    .font(.caption)
                // Show format badge
                if shouldUse3DMode {
                    if let settings = appModel.video3DSettings {
                        Text("(\(settings.format.shortLabel))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if let format = video.stereoscopicFormat {
                        Text("(\(format.shortLabel))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(6)
        }
    }

    /// Whether the current mode is 3D (either auto-detected or forced)
    private var shouldUse3DMode: Bool {
        // Explicitly set to 2D
        if appModel.videoStereoscopicOverride == false {
            return false
        }
        // Explicitly set to 3D or has custom settings
        if appModel.videoStereoscopicOverride == true || appModel.video3DSettings != nil {
            return true
        }
        // Auto-detect from video tags
        return appModel.selectedVideo?.isStereoscopic ?? false
    }

    private func enable3DMode(for video: GalleryVideo) {
        Task {
            // Check for saved settings first
            if let savedSettings = await Video3DSettingsTracker.shared.loadSettings(videoId: video.stashId) {
                await MainActor.run {
                    appModel.video3DSettings = savedSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            // Check for tag-detected settings
            if let tagSettings = Video3DSettings.from(video: video) {
                await MainActor.run {
                    appModel.video3DSettings = tagSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            // No saved or tag settings - show settings sheet
            await MainActor.run {
                appModel.showVideo3DSettingsSheet = true
            }
        }
    }

    private var currentModeIcon: String {
        shouldUse3DMode ? "view.3d" : "view.2d"
    }

    private var currentModeLabel: String {
        shouldUse3DMode ? "3D" : "2D"
    }
}
