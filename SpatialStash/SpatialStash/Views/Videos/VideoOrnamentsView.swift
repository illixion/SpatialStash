/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation and back button.
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    let videoCount: Int

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
    }
}
