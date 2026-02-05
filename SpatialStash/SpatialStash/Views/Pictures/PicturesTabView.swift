/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab.
 Pictures open in a pushed window (see PushedPictureView) via pushWindow.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        GalleryGridView()
            .environment(appModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
