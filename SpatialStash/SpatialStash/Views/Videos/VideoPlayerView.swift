/*
 Spatial Stash - Video Player View

 Web-based video player using WKWebView for WebM and other format support.
 */

import SwiftUI

struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let video = appModel.selectedVideo {
                WebVideoPlayerView(
                    videoURL: video.streamURL,
                    apiKey: appModel.stashAPIKey.isEmpty ? nil : appModel.stashAPIKey
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(video.id) // Force recreate when video changes
            } else {
                // No video selected state
                VStack(spacing: 20) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No video selected")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
