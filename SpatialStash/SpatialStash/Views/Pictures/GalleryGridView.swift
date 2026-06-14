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
    /// Snapshot of the source cell's loaded thumbnail at long-press
    /// time. Seeds the QL view's initial paint so we never show the
    /// gray loading state during the pop animation.
    @State private var quickLookSeedImage: UIImage?
    @State private var cellFrames: [UUID: CGRect] = [:]
    private let gallerySpace = "gallery"

    private let gridSpacing: CGFloat = 16
    /// Matches the ScrollView's `.padding()` so the available content width
    /// is computed correctly from the GeometryReader's outer width.
    private let gridContentInset: CGFloat = 16
    /// Preferred (and maximum) thumbnail edge. Wide windows keep cells at
    /// this size and add columns; narrow windows shrink below it instead of
    /// dropping a column.
    private let preferredCellSize: CGFloat = 200
    /// Never lay out fewer than this many columns — once the window is too
    /// narrow to fit them at `preferredCellSize`, thumbnails shrink to fit.
    private let minColumns = 4

    /// Resolve the column layout and cell edge for a given container width.
    /// `.adaptive` can't express a column-count floor (it just drops to
    /// fewer, larger-than-minimum columns), so we size the grid manually.
    private func gridLayout(forWidth width: CGFloat) -> (columns: [GridItem], cellSize: CGFloat) {
        guard width > 0 else {
            return (Array(repeating: GridItem(.fixed(preferredCellSize), spacing: gridSpacing),
                          count: minColumns), preferredCellSize)
        }
        let available = max(preferredCellSize, width - gridContentInset * 2)
        // How many full-size cells fit at the preferred edge.
        let natural = Int((available + gridSpacing) / (preferredCellSize + gridSpacing))
        let count = max(minColumns, natural)
        // Derive the actual edge from the resolved column count. When the
        // window can't fit `count` cells at full size (i.e. natural < minColumns),
        // this falls below preferredCellSize, increasing density.
        let raw = (available - gridSpacing * CGFloat(count - 1)) / CGFloat(count)
        let cellSize = min(preferredCellSize, raw)
        let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: gridSpacing), count: count)
        return (columns, cellSize)
    }

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
                GeometryReader { geo in
                    let layout = gridLayout(forWidth: geo.size.width)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                                ForEach(appModel.galleryImages) { image in
                                    thumbnailCell(for: image, cellSize: layout.cellSize)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: gallerySpace)
        .onPreferenceChange(CellFramePreferenceKey.self) { cellFrames = $0 }
        .overlay {
            // Outer GeometryReader resolves container size on the SAME
            // render commit that the QL view is inserted — feeding it
            // in as a parameter means the QL's first paint already has
            // correct geometry (no flicker from a layout-settle pass).
            GeometryReader { geo in
                if let quickLookImage {
                    let useScalePop = !appModel.effectiveReduceMotion
                    let sourceFrame = cellFrames[quickLookImage.id]
                    QuickLook3DView(
                        image: quickLookImage,
                        sourceFrame: sourceFrame,
                        containerSize: geo.size,
                        useScalePop: useScalePop,
                        initialImage: quickLookSeedImage,
                        onDismiss: {
                            // Suppress any inherited animation context
                            // (visionOS occasionally leaves one behind
                            // after gesture recognition, especially
                            // post-swipe-dismiss). Without this, the
                            // cell's opacity flip back to 1 rides the
                            // ambient transaction and the thumbnail
                            // "flies in" instead of snapping into place.
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                self.quickLookImage = nil
                                self.quickLookSeedImage = nil
                            }
                        }
                    )
                    .zIndex(10)
                }
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
    private func thumbnailCell(for image: GalleryImage, cellSize: CGFloat) -> some View {
        if appModel.isSelectingImages {
            GalleryThumbnailView(image: image, size: cellSize)
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
            let useScalePop = !appModel.effectiveReduceMotion
            GalleryThumbnailView(
                image: image,
                size: cellSize,
                onTap: {
                    appModel.lastViewedImageId = image.id
                    onImageSelected?(image)
                },
                onLongPress: { thumb in
                    // Capture the cell's loaded UIImage so QL can paint
                    // it immediately at the start of the animation.
                    quickLookSeedImage = thumb
                    // QL drives its own present animation from @State,
                    // so we just install it — no withAnimation wrapper.
                    quickLookImage = image
                },
                quickLookActive: quickLookImage?.id == image.id,
                cellCoordinateSpace: gallerySpace
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
