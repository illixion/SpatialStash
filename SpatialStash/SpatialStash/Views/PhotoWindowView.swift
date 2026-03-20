/*
 Spatial Stash - Photo Window View

 Window view for displaying individual photos.
 Handles two modes:
 - Pushed (wasPushed=true): opened via pushWindow from gallery, dismiss returns to gallery
 - Standalone (wasPushed=false): opened via openWindow as independent pop-out window
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 */

import SwiftUI

struct PhotoWindowView: View {
    let wasPushed: Bool
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var pendingPopOutImage: GalleryImage? = nil
    @State private var showDuplicateWindowAlert: Bool = false

    init(windowValue: PhotoWindowValue, appModel: AppModel) {
        self.wasPushed = windowValue.wasPushed
        _windowModel = State(initialValue: PhotoWindowModel(
            image: windowValue.image,
            appModel: appModel,
            // Only register as pop-out for standalone windows (not pushed)
            // so pushed windows don't trigger duplicate detection against themselves
            popOutWindowValue: windowValue.wasPushed ? nil : windowValue
        ))
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
                    context: wasPushed ? .pushedFromGallery : .standalone,
                    onGalleryButtonTap: {
                        if windowModel.isSlideshowActive {
                            windowModel.stopSlideshow()
                        }
                        if wasPushed {
                            dismissWindow()
                        } else {
                            appModel.showMainWindow(openWindow: openWindow)
                        }
                    },
                    extraButtons: {
                        if wasPushed {
                            Group {
                                Divider()
                                    .frame(height: 24)

                                popOutButton
                            }
                        }
                    }
                )
            }
        )
        .onAppear {
            appModel.lastViewedImageId = windowModel.image.id
            windowModel.start()
            windowModel.startAutoHideTimer()
        }
        .onDisappear {
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
                    dismissWindow()
                }
            }
            Button("Open New") {
                if let image = pendingPopOutImage {
                    appModel.enqueuePhotoWindowOpen(image, bypassDuplicatePrompt: true)
                    pendingPopOutImage = nil
                    dismissWindow()
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
                dismissWindow()
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
