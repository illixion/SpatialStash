/*
 Spatial Stash - Window Group Restore Sheet

 Sheet displaying a thumbnail grid of images in a saved window group.
 Supports individual restore, context menu delete, and adding open windows.
 */

import SwiftUI

struct WindowGroupRestoreSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    let group: SavedWindowGroup
    @State private var restoredImageIds: Set<UUID> = []
    @State private var showAddSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                let liveGroup = appModel.savedWindowGroups.first { $0.id == group.id }
                let images = liveGroup?.images ?? []

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(images) { image in
                        Button {
                            openWindow(id: "photo-detail", value: PhotoWindowValue(image: image))
                            restoredImageIds.insert(image.id)
                        } label: {
                            WindowGroupThumbnailView(image: image)
                                .opacity(restoredImageIds.contains(image.id) ? 0.5 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .hoverEffectDisabled()
                        .hoverEffect(LiftHoverEffect())
                        .contextMenu {
                            Button(role: .destructive) {
                                appModel.removeImageFromWindowGroup(group, imageId: image.id)
                                if appModel.savedWindowGroups.first(where: { $0.id == group.id }) == nil {
                                    dismiss()
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        showAddSheet = true
                    } label: {
                        ZStack {
                            Color.secondary.opacity(0.2)
                            Image(systemName: "plus")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 150, height: 150)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.openPopOutImagesNotInGroup(group).isEmpty)
                }
                .padding()
            }
            .navigationTitle(group.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddFromOpenWindowsSheet(group: group)
            }
        }
    }
}

private struct WindowGroupThumbnailView: View {
    let image: GalleryImage
    @State private var loadedImage: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)

            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 150, height: 150)
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .task {
            if let result = await ImageLoader.shared.loadThumbnailWithData(from: image.thumbnailURL) {
                loadedImage = cropToSquare(result.image)
            }
            isLoading = false
        }
    }

    private func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2
        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
