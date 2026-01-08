/*
 Spatial Stash - Stereoscopic Video View

 View for displaying stereoscopic 3D video converted to MV-HEVC.
 Handles download and conversion, then launches immersive space for 3D playback.
 */

import SwiftUI
import AVFoundation
import AVKit

struct StereoscopicVideoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @StateObject private var player = StereoscopicVideoPlayer()
    @State private var fallbackTo2D = false
    @State private var hasEnteredImmersiveSpace = false

    let video: GalleryVideo

    var body: some View {
        ZStack {
            if fallbackTo2D {
                // Fallback to 2D web player with original stream
                WebVideoPlayerView(
                    videoURL: video.streamURL,
                    apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
                )
            } else if hasEnteredImmersiveSpace {
                // Show minimal UI when in immersive space
                immersiveSpaceActiveView
            } else {
                // Show progress/error overlays during download/conversion
                Color.black
                    .aspectRatio(16/9, contentMode: .fit)

                overlayContent
            }
        }
        .onAppear {
            startPlayback()
        }
        .onDisappear {
            Task {
                await exitImmersiveSpace()
            }
            player.stop()
        }
        .onChange(of: player.state) { oldState, newState in
            // When playback is ready, open immersive space
            if case .playing = newState, !hasEnteredImmersiveSpace, !fallbackTo2D {
                Task {
                    await enterImmersiveSpace()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stereoscopicFallbackTo2D)) { notification in
            if let notificationVideo = notification.userInfo?["video"] as? GalleryVideo,
               notificationVideo.id == video.id {
                Task {
                    await exitImmersiveSpace()
                }
                fallbackTo2D = true
            }
        }
    }

    // MARK: - Immersive Space Active View

    private var immersiveSpaceActiveView: some View {
        // Empty view - immersive space handles its own UI
        Color.clear
            .frame(width: 1, height: 1)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayContent: some View {
        switch player.state {
        case .downloading(let progress):
            progressOverlay(
                title: "Downloading Video",
                progress: progress,
                detail: player.currentChunkInfo
            )

        case .converting(let progress):
            progressOverlay(
                title: "Converting to 3D",
                progress: progress,
                detail: player.currentChunkInfo
            )

        case .error(let message):
            errorOverlay(message: message)

        case .playing, .paused, .idle:
            // Show loading indicator while transitioning to immersive space
            if !hasEnteredImmersiveSpace && player.convertedFileURL != nil {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Entering 3D mode...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }

        // Format indicator badge (only during loading states)
        if case .downloading = player.state {
            formatBadgeView
        } else if case .converting = player.state {
            formatBadgeView
        }
    }

    private var formatBadgeView: some View {
        VStack {
            HStack {
                Spacer()
                formatBadge
                    .padding()
            }
            Spacer()
        }
    }

    private func progressOverlay(title: String, progress: Double, detail: String) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 250)
                .tint(.white)

            Text("\(Int(progress * 100))%")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private func errorOverlay(message: String) -> some View {
        let isSimulatorError = message.contains("Simulator") || message.contains("physical device")

        return VStack(spacing: 16) {
            Image(systemName: isSimulatorError ? "visionpro" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(isSimulatorError ? .blue : .orange)

            Text(isSimulatorError ? "Device Required" : "Playback Error")
                .font(.title2)
                .fontWeight(.semibold)

            Text(isSimulatorError
                 ? "Stereoscopic 3D video conversion requires a physical Apple Vision Pro. The Simulator cannot encode MV-HEVC video."
                 : message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if isSimulatorError {
                Button("Play as 2D Instead") {
                    fallbackTo2D = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 16) {
                    Button("Retry") {
                        startPlayback()
                    }
                    .buttonStyle(.bordered)

                    Button("Play as 2D") {
                        fallbackTo2D = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private var formatBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "view.3d")
            if let format = video.stereoscopicFormat {
                Text(format.shortLabel)
            } else {
                Text("3D")
            }
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func startPlayback() {
        fallbackTo2D = false
        hasEnteredImmersiveSpace = false
        Task {
            await player.play(
                video: video,
                apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
            )
        }
    }

    private func enterImmersiveSpace() async {
        guard let convertedURL = player.convertedFileURL else {
            print("[StereoscopicVideoView] No converted URL available for immersive playback")
            return
        }

        // Store video info in AppModel for ImmersiveVideoView
        appModel.immersiveVideo = video
        appModel.immersiveVideoURL = convertedURL

        // Stop the player since ImmersiveVideoView will create its own
        player.stop()

        // Open the immersive space
        switch await openImmersiveSpace(id: "StereoscopicVideoSpace") {
        case .opened:
            hasEnteredImmersiveSpace = true
            appModel.isStereoscopicImmersiveSpaceShown = true
            print("[StereoscopicVideoView] Immersive space opened successfully")
        case .error:
            print("[StereoscopicVideoView] Failed to open immersive space")
            fallbackTo2D = true
        case .userCancelled:
            print("[StereoscopicVideoView] User cancelled immersive space")
            fallbackTo2D = true
        @unknown default:
            print("[StereoscopicVideoView] Unknown immersive space result")
            fallbackTo2D = true
        }
    }

    private func exitImmersiveSpace() async {
        if hasEnteredImmersiveSpace {
            await dismissImmersiveSpace()
            hasEnteredImmersiveSpace = false
            appModel.isStereoscopicImmersiveSpaceShown = false
            appModel.immersiveVideo = nil
            appModel.immersiveVideoURL = nil
        }
    }
}

// MARK: - Preview

#if DEBUG
struct StereoscopicVideoView_Previews: PreviewProvider {
    static var previews: some View {
        StereoscopicVideoView(
            video: GalleryVideo(
                stashId: "preview",
                thumbnailURL: URL(string: "https://example.com/thumb.jpg")!,
                streamURL: URL(string: "https://example.com/video.mp4")!,
                title: "Preview Video",
                duration: 120,
                isStereoscopic: true,
                stereoscopicFormat: .sideBySide
            )
        )
        .environment(AppModel())
    }
}
#endif
