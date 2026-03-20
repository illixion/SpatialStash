/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab.
 Pictures open via pushWindow (gallery is backgrounded and restored on dismiss)
 or via openWindow when "Open media in new windows" is enabled.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.pushWindow) private var pushWindow
    
    var body: some View {
        GalleryGridView(onImageSelected: { image in
            if appModel.openMediaInNewWindows {
                appModel.enqueuePhotoWindowOpen(image)
            } else {
                pushWindow(id: "photo-detail", value: PhotoWindowValue(image: image, wasPushed: true))
            }
        })
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
