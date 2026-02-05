/*
 Spatial Stash - Gallery Grid View

 LazyVGrid-based gallery view with lazy loading for thumbnails.
 */

import SwiftUI
import UIKit

struct GalleryGridView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        Group {
            if appModel.galleryImages.isEmpty && appModel.isLoadingGallery {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading images...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.galleryImages.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No images available")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Gallery grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(appModel.galleryImages) { image in
                            GalleryThumbnailView(image: image) {
                                appModel.selectImageForDetail(image)
                            }
                            .id(image.id)
                            .onAppear {
                                // Lazy loading trigger - load more when last item appears
                                if image == appModel.galleryImages.last && appModel.hasMorePages {
                                    Task {
                                        await appModel.loadNextPage()
                                    }
                                }
                            }
                        }

                        if appModel.isLoadingGallery {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Ensure freeform resizing in gallery view
            if let windowScene = resolvedWindowScene {
                windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
            }
        }
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
    }

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
