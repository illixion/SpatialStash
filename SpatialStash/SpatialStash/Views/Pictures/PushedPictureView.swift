/*
 Spatial Stash - Pushed Picture View

 Picture viewer that is pushed from the gallery grid using pushWindow.
 Dismissing this view returns to the gallery with preserved state.
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 */

import SwiftUI

struct PushedPictureView: View {
    let image: GalleryImage
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var pendingPopOutImage: GalleryImage? = nil

    init(image: GalleryImage, appModel: AppModel) {
        self.image = image
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
                        context: .pushedFromGallery,
                        onGalleryButtonTap: {
                            if windowModel.isSlideshowActive {
                                windowModel.stopSlideshow()
                            }
                            dismissWindow()
                        },
                        extraButtons: {
                            Group {
                                Divider()
                                    .frame(height: 24)

                                popOutButton
                            }
                        }
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
            .alert(
                "Memory Warning",
                isPresented: Bindable(appModel).showMemoryWarningAlert
            ) {
                Button("Open Anyway") {
                    if let image = pendingPopOutImage {
                        openWindow(id: "photo-detail", value: image)
                        pendingPopOutImage = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingPopOutImage = nil
                }
            } message: {
                Text("Opening another window may cause the app to run out of memory. You have \(appModel.openPhotoWindowCount) windows open.")
            }
    }

    // MARK: - Pop Out Button

    private var popOutButton: some View {
        Button {
            let image = windowModel.image
            if appModel.memoryBudgetExceeded {
                pendingPopOutImage = image
                appModel.showMemoryWarningAlert = true
            } else {
                openWindow(id: "photo-detail", value: image)
            }
        } label: {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Pop Out")
    }
}
