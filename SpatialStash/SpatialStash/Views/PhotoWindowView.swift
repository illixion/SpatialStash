/*
 Spatial Stash - Photo Window View

 Standalone window view for displaying individual photos.
 Each photo opens in its own window with independent state.
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 */

import SwiftUI

struct PhotoWindowView: View {
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    init(image: GalleryImage, appModel: AppModel) {
        _windowModel = State(initialValue: PhotoWindowModel(image: image, appModel: appModel))
    }

    var body: some View {
        PhotoDisplayView(windowModel: windowModel, enableSwipeNavigation: true)
            .ornament(
                visibility: windowModel.isUIHidden ? .hidden : .visible,
                attachmentAnchor: .scene(.bottomFront),
                ornament: {
                    PhotoOrnamentView(
                        windowModel: windowModel,
                        context: .standalone,
                        onGalleryButtonTap: {
                            if windowModel.isSlideshowActive {
                                windowModel.stopSlideshow()
                            }
                            openWindow(id: "main")
                        },
                        extraButtons: { EmptyView() }
                    )
                }
            )
            .onAppear {
                windowModel.start()
                windowModel.startAutoHideTimer()
            }
            .onDisappear {
                windowModel.cleanup()
            }
    }
}
