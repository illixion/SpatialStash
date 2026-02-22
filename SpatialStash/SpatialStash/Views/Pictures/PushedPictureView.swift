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
    @Environment(\.openWindow) private var openWindow

    @State private var pendingPopOutImage: GalleryImage? = nil
    @State private var showDuplicateWindowAlert: Bool = false

    init(image: GalleryImage, appModel: AppModel, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
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
                "Memory Warning",
                isPresented: Bindable(appModel).showMemoryWarningAlert
            ) {
                Button("Open Anyway") {
                    if let image = pendingPopOutImage {
                        if appModel.hasOpenPopOutWindow(for: image.fullSizeURL) {
                            showDuplicateWindowAlert = true
                        } else {
                            openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
                            pendingPopOutImage = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingPopOutImage = nil
                }
            } message: {
                Text("Opening another window may cause the app to run out of memory. You have \(appModel.openPhotoWindowCount) windows open.")
            }
            .alert(
                "Window Already Open",
                isPresented: $showDuplicateWindowAlert
            ) {
                Button("Summon") {
                    if let image = pendingPopOutImage {
                        // Dismiss existing pop-out windows for this image, then open a new one
                        // which appears at the user's current position
                        let existingValues = appModel.popOutWindowValues(for: image.fullSizeURL)
                        for value in existingValues {
                            dismissWindow(id: "photo-detail", value: value)
                        }
                        openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
                        pendingPopOutImage = nil
                    }
                }
                Button("Open New") {
                    if let image = pendingPopOutImage {
                        openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
                        pendingPopOutImage = nil
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
            if appModel.memoryBudgetExceeded {
                pendingPopOutImage = image
                appModel.showMemoryWarningAlert = true
            } else if appModel.hasOpenPopOutWindow(for: image.fullSizeURL) {
                pendingPopOutImage = image
                showDuplicateWindowAlert = true
            } else {
                openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
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
