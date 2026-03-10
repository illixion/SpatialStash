/*
 Spatial Stash - Local Video Player View

 AVPlayerViewController wrapper for playing local video files.
 Used by SharedVideoWindowView for shared-in videos.
 */

import AVKit
import SwiftUI

struct LocalVideoPlayerView: UIViewControllerRepresentable {
    let videoURL: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Use ambient audio session so we don't interrupt other video players
        try? AVAudioSession.sharedInstance().setCategory(.ambient)

        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        player.isMuted = true
        controller.player = player
        controller.allowsPictureInPicturePlayback = true

        // Loop playback
        context.coordinator.observeLooping(player: player)

        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Only update if URL actually changed
        if let currentAsset = controller.player?.currentItem?.asset as? AVURLAsset,
           currentAsset.url != videoURL {
            controller.player?.pause()
            let player = AVPlayer(url: videoURL)
            player.isMuted = true
            controller.player = player
            context.coordinator.observeLooping(player: player)
            player.play()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        private var loopObserver: Any?

        func observeLooping(player: AVPlayer) {
            // Remove previous observer
            if let observer = loopObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }

        deinit {
            if let observer = loopObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
