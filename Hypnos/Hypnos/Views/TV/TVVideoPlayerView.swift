/*
 Hypnos - tvOS fullscreen video player

 `AVPlayerViewController` rather than the native Metal path used elsewhere
 in the app: on tvOS it already gives the platform's own transport UI,
 scrubbing, and Menu-button dismissal for free, which is exactly the 10-foot
 experience this needs and none of `VideoWindowView`'s ornament/gesture
 machinery is built for a remote anyway (see `Hypnos/CLAUDE.md` "tvOS").

 There is no WebKit fallback on tvOS (`Hypnos/CLAUDE.md` "tvOS"), so this
 plays `GalleryVideo.streamURL` directly through AVFoundation. WebM/VP9
 sources decode because `HypnosApp` registers the supplemental VP9 decoder
 once at launch (tvOS 26.2+); anything neither AVFoundation nor that
 decoder can open simply fails to play — there is no second tier to fall
 back to.
 */

#if os(tvOS)

import AVKit
import SwiftUI

struct TVVideoPlayerView: View {
    let video: GalleryVideo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVAVPlayerViewControllerRepresentable(url: video.streamURL)
            .ignoresSafeArea()
            // Belt-and-suspenders: `AVPlayerViewController` normally handles
            // its own Menu-button exit when *presented* modally through
            // UIKit, but here it's embedded inside a SwiftUI
            // `fullScreenCover` via a plain representable, not presented
            // itself — verify on-device/simulator that Menu dismisses this,
            // and keep this handler either way.
            .onExitCommand { dismiss() }
    }
}

private struct TVAVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(url: url)
        item.applySpatialAudioPolicy()
        let player = AVPlayer(playerItem: item)
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

#endif
