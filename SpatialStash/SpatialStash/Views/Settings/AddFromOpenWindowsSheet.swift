/*
 Spatial Stash - Add From Open Windows Sheet

 Picker sheet for selecting currently-open pop-out images to add to a saved window group.
 */

import SwiftUI

struct AddFromOpenWindowsSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let group: SavedWindowGroup
    @State private var selectedImageIds: Set<UUID> = []

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            let availableImages = appModel.openPopOutImagesNotInGroup(group)

            if availableImages.isEmpty {
                Text("No open windows to add")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Add to \(group.name)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(availableImages) { image in
                            let isSelected = selectedImageIds.contains(image.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isSelected {
                                        selectedImageIds.remove(image.id)
                                    } else {
                                        selectedImageIds.insert(image.id)
                                    }
                                }
                            } label: {
                                SelectableThumbnailView(image: image, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .hoverEffectDisabled()
                            .hoverEffect(LiftHoverEffect())
                        }
                    }
                    .padding()
                }
                .navigationTitle("Add to \(group.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selectedImageIds.count))") {
                            let available = appModel.openPopOutImagesNotInGroup(group)
                            let imagesToAdd = available.filter { selectedImageIds.contains($0.id) }
                            appModel.addImagesToWindowGroup(group, images: imagesToAdd)
                            dismiss()
                        }
                        .disabled(selectedImageIds.isEmpty)
                    }
                }
            }
        }
    }
}

private struct SelectableThumbnailView: View {
    let image: GalleryImage
    let isSelected: Bool
    @State private var loadedImage: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
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

            ZStack {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .padding(8)
        }
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
