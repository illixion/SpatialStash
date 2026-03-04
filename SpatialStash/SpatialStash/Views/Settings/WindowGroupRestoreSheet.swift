/*
 Spatial Stash - Window Group Restore Sheet

 Sheet displaying a thumbnail grid of images in a saved window group.
 Supports individual restore, context menu delete, and adding open windows.
 */

import SwiftUI

struct WindowGroupRestoreSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let group: SavedWindowGroup
    @State private var restoredImageIds: Set<UUID> = []
    @State private var showAddSheet = false
    @State private var isSelectionMode = false
    @State private var selectedImageIds: Set<UUID> = []

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
                        ZStack(alignment: .topTrailing) {
                            Button {
                                if isSelectionMode {
                                    if selectedImageIds.contains(image.id) {
                                        selectedImageIds.remove(image.id)
                                    } else {
                                        selectedImageIds.insert(image.id)
                                    }
                                } else {
                                    appModel.enqueuePhotoWindowOpen(image)
                                    restoredImageIds.insert(image.id)
                                }
                            } label: {
                                WindowGroupThumbnailView(image: image)
                                    .opacity(restoredImageIds.contains(image.id) ? 0.5 : 1.0)
                            }
                            .buttonStyle(.plain)
                            .hoverEffectDisabled()
                            .hoverEffect(LiftHoverEffect())

                            // Selection checkmark in selection mode
                            if isSelectionMode {
                                ZStack {
                                    Circle()
                                        .fill(selectedImageIds.contains(image.id) ? Color.accentColor : Color.secondary.opacity(0.3))
                                    Image(systemName: selectedImageIds.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.white)
                                        .font(.title3)
                                }
                                .frame(width: 32, height: 32)
                                .padding(8)
                            }
                        }
                    }

                    if !isSelectionMode {
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
                        .hoverEffectDisabled()
                        .hoverEffect(LiftHoverEffect())
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddFromOpenWindowsSheet(group: group)
            }
            .navigationTitle(group.name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isSelectionMode.toggle()
                        selectedImageIds.removeAll()
                    } label: {
                        Image(systemName: isSelectionMode ? "pencil.circle.fill" : "pencil.circle")
                            .font(.title2)
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(isSelectionMode ? "Exit selection mode" : "Enter selection mode")
                    .accessibilityHint("Toggles multi-select mode")
                    .contentShape(Circle())
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Button(role: .destructive) {
                            for imageId in selectedImageIds {
                                appModel.removeImageFromWindowGroup(group, imageId: imageId)
                            }
                            selectedImageIds.removeAll()
                            isSelectionMode = false

                            // If group is empty, dismiss
                            if appModel.savedWindowGroups.first(where: { $0.id == group.id })?.images.isEmpty ?? true {
                                dismiss()
                            }
                        } label: {
                            Text("Delete")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedImageIds.isEmpty)
                    } else {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.title3)
                        }
                    }
                }
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
