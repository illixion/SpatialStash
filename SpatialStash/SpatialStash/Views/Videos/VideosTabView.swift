/*
 Spatial Stash - Videos Tab View

 Container view for the Videos tab.
 Videos open via pushWindow (gallery is backgrounded and restored on dismiss)
 or via openWindow when "Open media in new windows" is enabled.
 */

import SwiftUI

struct VideosTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            AppliedContainerBanner(isVideo: true)
            VideoGalleryView()
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
