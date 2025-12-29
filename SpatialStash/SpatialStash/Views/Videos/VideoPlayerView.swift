/*
 Spatial Stash - Video Player View

 AVKit-based video player for playing videos from Stash.
 */

import SwiftUI
import AVKit

struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        Group {
            if let error = error {
                // Error state
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 64))
                        .foregroundColor(.red)
                    Text("Failed to load video")
                        .font(.title2)
                    Text(error.localizedDescription)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading video...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player = player {
                // Video player
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            }
        }
        .task {
            await loadVideo()
        }
        .onChange(of: appModel.selectedVideo) { _, newVideo in
            if newVideo != nil {
                Task {
                    await loadVideo()
                }
            }
        }
    }

    private func loadVideo() async {
        guard let video = appModel.selectedVideo else {
            error = VideoPlayerError.noVideoSelected
            return
        }

        isLoading = true
        error = nil

        // Create player with the stream URL
        let newPlayer = AVPlayer(url: video.streamURL)

        // Wait a moment for the player to load
        do {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        } catch {
            // Ignore cancellation
        }

        player = newPlayer
        isLoading = false
    }
}

enum VideoPlayerError: Error, LocalizedError {
    case noVideoSelected

    var errorDescription: String? {
        switch self {
        case .noVideoSelected:
            return "No video selected"
        }
    }
}
