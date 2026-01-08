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

                // Stereoscopic format toggle (for 3D videos)
                if let video = appModel.selectedVideo, video.isStereoscopic {
                    stereoscopicToggle(for: video)
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
    private func stereoscopicToggle(for video: GalleryVideo) -> some View {
        Divider()
            .frame(height: 24)

        Menu {
            Button {
                appModel.videoStereoscopicOverride = nil
            } label: {
                HStack {
                    Text("3D (Stereo)")
                    if appModel.videoStereoscopicOverride == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                appModel.videoStereoscopicOverride = false
            } label: {
                HStack {
                    Text("2D (Left Eye)")
                    if appModel.videoStereoscopicOverride == false {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentModeIcon)
                Text(currentModeLabel)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(6)
        }

        // Format badge for stereoscopic videos
        if let format = video.stereoscopicFormat {
            Text(format.shortLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
        }
    }

    private var currentModeIcon: String {
        appModel.videoStereoscopicOverride == false ? "view.2d" : "view.3d"
    }

    private var currentModeLabel: String {
        appModel.videoStereoscopicOverride == false ? "2D" : "3D"
    }
}
