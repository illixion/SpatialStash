/*
 Spatial Stash - Pictures Tab View

 Container view for the Pictures tab.
 Pictures open as an in-window view swap within the main window.
 */

import SwiftUI

struct PicturesTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedImage: GalleryImage? = nil

    var body: some View {
        Group {
            if !appModel.openImagesInSeparateWindows, let image = selectedImage {
                PushedPictureView(image: image, appModel: appModel, onDismiss: {
                    selectedImage = nil
                })
            } else {
                GalleryGridView(onImageSelected: { image in
                    if appModel.openImagesInSeparateWindows {
                        openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
                    } else {
                        selectedImage = image
                    }
                })
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: appModel.openImagesInSeparateWindows) { _, isEnabled in
            if isEnabled {
                selectedImage = nil
            }
        }
    }
}
