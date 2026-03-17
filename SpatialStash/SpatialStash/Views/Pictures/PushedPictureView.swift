/*
 Spatial Stash - Pushed Picture View

 Picture viewer shown in-window from the gallery grid via view swap.
 Dismissing this view returns to the gallery with preserved state.
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 */

import SwiftUI

struct PushedPictureView: View {
    let image: GalleryImage
    let onDismiss: () -> Void
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var pendingPopOutImage: GalleryImage? = nil
    @State private var showDuplicateWindowAlert: Bool = false

    init(image: GalleryImage, appModel: AppModel, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
        _windowModel = State(initialValue: PhotoWindowModel(image: image, appModel: appModel, useRealityKitDisplay: false))
    }

    var body: some View {
        PhotoDisplayView(windowModel: windowModel, enableSwipeNavigation: true)
        .persistentSystemOverlays(windowModel.isWindowControlsHidden ? .hidden : .visible)
        .ornament(
                visibility: windowModel.isUIHidden ? .hidden : .visible,
                attachmentAnchor: .scene(.bottomFront),
                contentAlignment: .top,
                ornament: {
                    PhotoOrnamentView(
                        windowModel: windowModel,
                        context: .pushedFromGallery,
                        onGalleryButtonTap: {
                            if windowModel.isSlideshowActive {
                                windowModel.stopSlideshow()
                            }
                            onDismiss()
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
                appModel.isPictureViewerActive = true
                appModel.lastViewedImageId = image.id
                windowModel.start()
                windowModel.startAutoHideTimer()
            }
            .onDisappear {
                appModel.isPictureViewerActive = false
                windowModel.cleanup()
            }
            .alert(
                "Window Already Open",
                isPresented: $showDuplicateWindowAlert
            ) {
                Button("Summon") {
                    if let image = pendingPopOutImage {
                        let existingValues = appModel.popOutWindowValues(for: image.fullSizeURL)
                        for value in existingValues {
                            dismissWindow(id: "photo-detail", value: value)
                        }
                        appModel.enqueuePhotoWindowOpen(image, bypassDuplicatePrompt: true)
                        pendingPopOutImage = nil
                        onDismiss()
                    }
                }
                Button("Open New") {
                    if let image = pendingPopOutImage {
                        appModel.enqueuePhotoWindowOpen(image, bypassDuplicatePrompt: true)
                        pendingPopOutImage = nil
                        onDismiss()
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingPopOutImage = nil
                }
            } message: {
                Text("A window for this image is already open. You can summon it to your current position or open a new window.")
            }
    }

    // MARK: - Pop Out Button

    private var popOutButton: some View {
        Button {
            let image = windowModel.image
            if appModel.hasOpenPopOutWindow(for: image.fullSizeURL) {
                pendingPopOutImage = image
                showDuplicateWindowAlert = true
            } else {
                appModel.enqueuePhotoWindowOpen(image)
                if windowModel.isSlideshowActive {
                    windowModel.stopSlideshow()
                }
                onDismiss()
            }
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.forward")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isLoadingDetailImage)
        .help("Pop Out")
    }
}
