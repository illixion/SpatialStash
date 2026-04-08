/*
 Spatial Stash - Remote Video Window View

 Plays video triggered by WebSocket playVideo commands.
 Appears as a standalone window.
 */

import AVKit
import SwiftUI

struct RemoteVideoWindowView: View {
    let windowValue: RemoteVideoWindowValue
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .overlay(ProgressView())
            }
        }
        .onAppear {
            let avPlayer = AVPlayer(url: windowValue.videoURL)
            avPlayer.play()
            self.player = avPlayer
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
