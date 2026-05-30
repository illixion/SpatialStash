/*
 Spatial Stash - Gallery Grid View

 LazyVGrid-based gallery view with lazy loading for thumbnails.
 Supports multi-select mode for bulk operations.
 */

import SwiftUI
import UIKit

struct GalleryGridView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    var onImageSelected: ((GalleryImage) -> Void)? = nil

    @State private var showBulkDeleteConfirmation = false
    @State private var quickLookImage: GalleryImage?
    @Namespace private var quickLookNamespace

    let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        Group {
            if appModel.imageSource is StaticURLImageSource && !appModel.demoImagesConfirmed {
                demoConfirmationView
            } else if appModel.galleryImages.isEmpty && appModel.isLoadingGallery {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(appModel.galleryImages) { image in
                                thumbnailCell(for: image)
                                    .id(image.id)
                                    .onAppear {
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
                    .refreshable {
                        await appModel.loadInitialGallery()
                    }
                    .onAppear {
                        if let lastId = appModel.lastViewedImageId {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(lastId, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let quickLookImage {
                let useGeometry = !appModel.effectiveReduceMotion
                QuickLook3DView(
                    image: quickLookImage,
                    namespace: useGeometry ? quickLookNamespace : nil,
                    useMatchedGeometry: useGeometry,
                    onDismiss: {
                        let anim: Animation = useGeometry
                            ? .spring(response: 0.4, dampingFraction: 0.85)
                            : .easeInOut(duration: 0.2)
                        withAnimation(anim) {
                            self.quickLookImage = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.isSelectingImages {
                selectionToolbar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if appModel.isSelectingImages {
                        appModel.exitImageSelection()
                    } else {
                        appModel.isSelectingImages = true
                    }
                } label: {
                    Text(appModel.isSelectingImages ? "Cancel" : "Select")
                }
            }
        }
        .onAppear {
            if let windowScene = resolvedWindowScene {
                windowScene.requestGeometryUpdate(.Vision(
                    size: CGSize(width: 1200, height: 800),
                    resizingRestrictions: .freeform
                ))
            }
        }
        .task {
            if appModel.galleryImages.isEmpty {
                await appModel.loadInitialGallery()
            }
        }
        .confirmationDialog(
            "Delete \(appModel.selectedImageIds.count) Image\(appModel.selectedImageIds.count == 1 ? "" : "s")",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Stash", role: .destructive) {
                Task { await bulkDelete(deleteFile: false) }
            }
            Button("Delete Files from Disk", role: .destructive) {
                Task { await bulkDelete(deleteFile: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var demoConfirmationView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Load Sample Images?")
                .font(.title2)
            Text("No Stash server is configured. Tapping Load will fetch demo images from an external site.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Load Sample Images") {
                appModel.demoImagesConfirmed = true
                Task { await appModel.loadInitialGallery() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func thumbnailCell(for image: GalleryImage) -> some View {
        if appModel.isSelectingImages {
            GalleryThumbnailView(image: image)
                .overlay(alignment: .topTrailing) {
                    let isSelected = image.stashId.map { appModel.selectedImageIds.contains($0) } ?? false
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }
                .onTapGesture {
                    guard let stashId = image.stashId else { return }
                    if appModel.selectedImageIds.contains(stashId) {
                        appModel.selectedImageIds.remove(stashId)
                    } else {
                        appModel.selectedImageIds.insert(stashId)
                    }
                }
        } else {
            let useGeometry = !appModel.effectiveReduceMotion
            GalleryThumbnailView(
                image: image,
                onTap: {
                    appModel.lastViewedImageId = image.id
                    onImageSelected?(image)
                },
                onLongPress: {
                    let anim: Animation = useGeometry
                        ? .spring(response: 0.45, dampingFraction: 0.82)
                        : .easeInOut(duration: 0.2)
                    withAnimation(anim) {
                        quickLookImage = image
                    }
                },
                quickLookNamespace: useGeometry ? quickLookNamespace : nil,
                quickLookActive: quickLookImage?.id == image.id
            )
        }
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 20) {
            Button {
                let allIds = Set(appModel.galleryImages.compactMap(\.stashId))
                if appModel.selectedImageIds == allIds {
                    appModel.selectedImageIds.removeAll()
                } else {
                    appModel.selectedImageIds = allIds
                }
            } label: {
                let allIds = Set(appModel.galleryImages.compactMap(\.stashId))
                Text(appModel.selectedImageIds == allIds ? "Deselect All" : "Select All")
            }

            Spacer()

            Text("\(appModel.selectedImageIds.count) selected")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Button("Delete", role: .destructive) {
                showBulkDeleteConfirmation = true
            }
            .disabled(appModel.selectedImageIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Bulk Delete

    private func bulkDelete(deleteFile: Bool) async {
        let ids = Array(appModel.selectedImageIds)
        guard !ids.isEmpty else { return }
        do {
            try await appModel.apiClient.destroyImages(ids: ids, deleteFile: deleteFile)
            appModel.removeDeletedImages(stashIds: Set(ids))
            if appModel.selectedImageIds.isEmpty {
                appModel.exitImageSelection()
            }
        } catch {}
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
