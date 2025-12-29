/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab that switches between gallery and detail views.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isShowingDetailView {
                // ImagePresentationView gets SceneDelegate from parent environment
                ImagePresentationView()
            } else {
                GalleryGridView()
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
