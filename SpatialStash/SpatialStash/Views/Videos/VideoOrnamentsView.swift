/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    let videoCount: Int

    /// Callback to change stereoscopic mode: nil = auto, true = force 3D, false = force 2D
    var onStereoscopicModeChange: ((Bool?) -> Void)? = nil

    /// Current stereoscopic mode override
    @State private var stereoscopicOverride: Bool? = nil

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

                // Stereoscopic format toggle (for 3D videos or when override is active)
                if let video = appModel.selectedVideo,
                   video.isStereoscopic || stereoscopicOverride != nil {
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
        .onChange(of: appModel.selectedVideo?.id) {
            // Reset override when video changes
            stereoscopicOverride = nil
        }
    }

    @ViewBuilder
    private func stereoscopicToggle(for video: GalleryVideo) -> some View {
        Divider()
            .frame(height: 24)

        Menu {
            Button {
                stereoscopicOverride = nil
                onStereoscopicModeChange?(nil)
            } label: {
                HStack {
                    Text("Auto-detect")
                    if stereoscopicOverride == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                stereoscopicOverride = true
                onStereoscopicModeChange?(true)
            } label: {
                HStack {
                    Text("Force 3D")
                    if stereoscopicOverride == true {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                stereoscopicOverride = false
                onStereoscopicModeChange?(false)
            } label: {
                HStack {
                    Text("Force 2D")
                    if stereoscopicOverride == false {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentModeIcon(for: video))
                Text(currentModeLabel(for: video))
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(6)
        }

        // Format badge for stereoscopic videos
        if video.isStereoscopic, let format = video.stereoscopicFormat {
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

    private func currentModeIcon(for video: GalleryVideo) -> String {
        switch stereoscopicOverride {
        case .some(true):
            return "view.3d"
        case .some(false):
            return "view.2d"
        case .none:
            return video.isStereoscopic ? "view.3d" : "view.2d"
        }
    }

    private func currentModeLabel(for video: GalleryVideo) -> String {
        switch stereoscopicOverride {
        case .some(true):
            return "3D"
        case .some(false):
            return "2D"
        case .none:
            return video.isStereoscopic ? "3D" : "2D"
        }
    }
}
