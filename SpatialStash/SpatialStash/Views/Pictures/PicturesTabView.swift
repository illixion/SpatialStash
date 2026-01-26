/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab.
 Photos open in separate windows (see PhotoWindowView), not in this view.
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
