/*
 Spatial Stash - Videos Tab View

 Container view for the Videos tab with gallery grid and video player.
 */

import SwiftUI

struct VideosTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isShowingVideoDetail {
                VideoPlayerView()
            } else {
                VideoGalleryView()
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
