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
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: videoURL)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Only update if URL actually changed
        if let currentAsset = controller.player?.currentItem?.asset as? AVURLAsset,
           currentAsset.url != videoURL {
            let player = AVPlayer(url: videoURL)
            controller.player = player
            player.play()
        }
    }
}
