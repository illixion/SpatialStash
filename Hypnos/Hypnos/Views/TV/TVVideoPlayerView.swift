/*
 Hypnos - tvOS fullscreen video player

 `AVPlayerViewController` rather than the native Metal path used elsewhere
 in the app: on tvOS it already gives the platform's own transport UI,
 scrubbing, and Menu-button dismissal for free, which is exactly the 10-foot
 experience this needs and none of `VideoWindowView`'s ornament/gesture
 machinery is built for a remote anyway (see `Hypnos/CLAUDE.md` "tvOS").

 There is no WebKit fallback on tvOS (`Hypnos/CLAUDE.md` "tvOS"), so this
 plays through AVFoundation only — but it does follow the same two moves the
 other players make before handing AVFoundation a URL:

 1. **Auth.** Every AVFoundation path in this app goes through
    `MediaAuthorization.shared.asset(for:)` (Hypnos commit ea220b7) so a
    Stash server behind a login, or Nextcloud's Basic auth, doesn't 401 —
    building a bare `AVPlayerItem(url:)` here would silently break exactly
    those two sources.
 2. **Stream-URL strategy.** `GalleryVideo.streamURL` is the original file;
    `NativeVideoDecodeProbe` decides whether AVFoundation can actually open
    it (VP9 in MP4 may now decode thanks to the supplemental decoder
    registered at launch — see `HypnosApp.init` — but WebM containers still
    can't). When it can't, and unlike the WebKit-based players elsewhere,
    there is no second player tier here — the *only* fallback is Stash's
    live HLS transcode (`GalleryVideo.transcodeStreamURL`). A source with
    neither simply can't play on tvOS; the view reports that rather than
    presenting a stuck black screen.

 A Photos-sourced video is a `photos-asset:///` identity, not something
 AVPlayer can open at all, so it is resolved to a real file URL first via
 `PhotosAssetStore`, the same as `VideoWindowModel.resolvePlaybackRenderer`.
 */

#if os(tvOS)

import AVKit
import os
import SwiftUI

struct TVVideoPlayerView: View {
    let video: GalleryVideo
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedURL: URL?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let resolvedURL {
                TVAVPlayerViewControllerRepresentable(url: resolvedURL) {
                    failureMessage = "This video's format isn't supported on Apple TV."
                    self.resolvedURL = nil
                }
                .ignoresSafeArea()
                // Belt-and-suspenders: `AVPlayerViewController` normally handles
                // its own Menu-button exit when *presented* modally through
                // UIKit, but here it's embedded inside a SwiftUI
                // `fullScreenCover` via a plain representable, not presented
                // itself — verify on-device/simulator that Menu dismisses this,
                // and keep this handler either way.
                .onExitCommand { dismiss() }
            } else if let failureMessage {
                ContentUnavailableView(
                    "Can't Play This Video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
                .onExitCommand { dismiss() }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onExitCommand { dismiss() }
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        var source = video.streamURL

        if PhotosAssetURL.isPhotosAsset(source) {
            guard let playable = await PhotosAssetStore.shared.playableURL(for: source) else {
                failureMessage = "This video is no longer available in Photos."
                return
            }
            source = playable
            // A resolved Photos file plays directly — nothing to authenticate
            // and no server transcode to fall back to.
            resolvedURL = source
            return
        }

        let authenticated = MediaAuthorization.shared.authorizedURL(source)
        if await NativeVideoDecodeProbe.canPlayNatively(url: authenticated) {
            AppLogger.videoWindow.info("[tvOS] playing original: \(authenticated.loggableDescription, privacy: .public)")
            resolvedURL = authenticated
            return
        }

        guard let transcode = video.transcodeStreamURL else {
            failureMessage = "This video's format isn't supported on Apple TV, and no server transcode is available."
            return
        }
        AppLogger.videoWindow.info("[tvOS] original undecodable — falling back to server transcode")
        resolvedURL = MediaAuthorization.shared.authorizedURL(transcode)
    }
}

private struct TVAVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL
    var onPlaybackFailed: () -> Void = {}

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let asset = MediaAuthorization.shared.asset(for: url)
        let item = AVPlayerItem(asset: asset)
        item.applySpatialAudioPolicy()
        let player = AVPlayer(playerItem: item)
        controller.player = player

        // Both observers are queued/dispatched on `.main`, so `Coordinator`
        // (`@unchecked Sendable`, like the app's other cross-boundary bridge
        // types — `SendableAVAsset`, `SendableTexture`) really is only ever
        // touched there; that conformance is what lets it cross into these
        // `@Sendable` NotificationCenter/KVO closures at all.
        let coordinator = context.coordinator
        coordinator.failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak coordinator] _ in
            coordinator?.onPlaybackFailed()
        }
        coordinator.statusObservation = item.observe(\.status, options: [.new]) { [weak coordinator] observedItem, _ in
            guard observedItem.status == .failed else { return }
            DispatchQueue.main.async {
                coordinator?.onPlaybackFailed()
            }
        }

        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onPlaybackFailed = onPlaybackFailed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackFailed: onPlaybackFailed)
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.statusObservation?.invalidate()
        if let observer = coordinator.failureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        uiViewController.player?.pause()
        uiViewController.player = nil
    }

    /// `@unchecked Sendable`: every access happens on the main queue (both
    /// observers above are registered with `queue: .main` / dispatched
    /// there), so the unchecked conformance states a real invariant rather
    /// than papering over one, the same shape as `SendableAVAsset` /
    /// `SendableTexture` elsewhere in the app.
    final class Coordinator: @unchecked Sendable {
        var onPlaybackFailed: () -> Void
        var failureObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?

        init(onPlaybackFailed: @escaping () -> Void) {
            self.onPlaybackFailed = onPlaybackFailed
        }
    }
}

#endif
