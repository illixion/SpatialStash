/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab with gallery grid and picture viewer.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isShowingDetailView {
                ImagePresentationView()
            } else {
                GalleryGridView()
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
