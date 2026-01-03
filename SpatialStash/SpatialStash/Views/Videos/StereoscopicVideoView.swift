/*
 Spatial Stash - Stereoscopic Video View

 RealityKit-based view for displaying stereoscopic 3D video using VideoMaterial.
 Handles MV-HEVC content converted from SBS/OU sources.
 */

import SwiftUI
import RealityKit
import AVFoundation
import Combine

struct StereoscopicVideoView: View {
    @Environment(AppModel.self) private var appModel
    @StateObject private var player = StereoscopicVideoPlayer()
    @State private var videoEntity: Entity?
    @State private var showControls = true
    @State private var fallbackTo2D = false

    let video: GalleryVideo

    var body: some View {
        ZStack {
            if fallbackTo2D {
                // Fallback to 2D web player
                WebVideoPlayerView(
                    videoURL: video.streamURL,
                    apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
                )
            } else {
                // RealityKit view for stereoscopic video
                realityContent

                // Overlays
                overlayContent
            }
        }
        .onAppear {
            startPlayback()
        }
        .onDisappear {
            player.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stereoscopicFallbackTo2D)) { notification in
            if let notificationVideo = notification.userInfo?["video"] as? GalleryVideo,
               notificationVideo.id == video.id {
                fallbackTo2D = true
            }
        }
        .gesture(
            TapGesture()
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if showControls {
                        appModel.startAutoHideTimer()
                    }
                }
        )
        .onChange(of: appModel.isUIHidden) { _, isHidden in
            showControls = !isHidden
        }
    }

    // MARK: - Reality Content

    @ViewBuilder
    private var realityContent: some View {
        RealityView { content in
            let entity = Entity()
            entity.name = "StereoscopicVideoContainer"

            // Create a plane mesh for video display
            // 16:9 aspect ratio, sized for comfortable viewing
            let mesh = MeshResource.generatePlane(width: 1.6, height: 0.9)
            let material = SimpleMaterial(color: .black, isMetallic: false)
            let modelComponent = ModelComponent(mesh: mesh, materials: [material])
            entity.components.set(modelComponent)

            // Position in front of user
            entity.position = SIMD3<Float>(0, 1.2, -2.0)

            content.add(entity)

            // Store reference for later material update
            Task { @MainActor in
                self.videoEntity = entity
            }
        } update: { content in
            // Update video material when player is ready
            updateVideoMaterial()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stereoscopicPlaybackReady)) { notification in
            if let avPlayer = notification.userInfo?["player"] as? AVPlayer {
                Task { @MainActor in
                    await applyVideoMaterial(player: avPlayer)
                }
            }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayContent: some View {
        switch player.state {
        case .loading:
            loadingOverlay(message: "Loading stereoscopic video...")

        case .buffering(let progress):
            bufferingOverlay(progress: progress)

        case .error(let message):
            errorOverlay(message: message)

        case .playing, .paused:
            if showControls {
                playbackControls
            }

        case .idle:
            EmptyView()
        }

        // Format indicator badge
        if player.state.isActive {
            VStack {
                HStack {
                    Spacer()
                    formatBadge
                        .padding()
                }
                Spacer()
            }
        }
    }

    private func loadingOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text(message)
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
    }

    private func bufferingOverlay(progress: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 200)
                .tint(.white)
            Text("Buffering... \(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.white)
            Text(player.currentChunkInfo)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Playback Error")
                .font(.title2)
                .fontWeight(.semibold)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

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
        .padding(32)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private var playbackControls: some View {
        VStack {
            Spacer()

            HStack(spacing: 24) {
                // Play/Pause button
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }

                // Progress indicator
                VStack(alignment: .leading, spacing: 4) {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Background track
                            Capsule()
                                .fill(Color.white.opacity(0.3))

                            // Buffer progress
                            Capsule()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: geo.size.width * player.bufferProgress)

                            // Playback progress
                            Capsule()
                                .fill(Color.white)
                                .frame(width: geo.size.width * progressPercentage)
                        }
                    }
                    .frame(height: 4)

                    // Time labels
                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(.caption2)
                    .foregroundColor(.white)
                }
                .frame(width: 280)

                // Chunk info
                Text(player.currentChunkInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 80)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .padding(.bottom, 60)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    private var progressPercentage: Double {
        guard player.duration > 0 else { return 0 }
        return min(1.0, player.currentTime / player.duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }

        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private func startPlayback() {
        fallbackTo2D = false
        Task {
            await player.play(
                video: video,
                apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
            )
        }
    }

    private func updateVideoMaterial() {
        // Called during RealityView update
        // Material is applied via notification when player is ready
    }

    private func applyVideoMaterial(player avPlayer: AVPlayer) async {
        guard let entity = videoEntity,
              var modelComponent = entity.components[ModelComponent.self] else {
            return
        }

        do {
            // Create VideoMaterial from the AVPlayer
            let videoMaterial = try await VideoMaterial(avPlayer: avPlayer)

            // Apply the material to the entity
            modelComponent.materials = [videoMaterial]
            entity.components.set(modelComponent)

        } catch {
            print("[StereoscopicVideoView] Failed to create VideoMaterial: \(error)")
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
