/*
 Spatial Stash - Gallery Thumbnail View

 Individual thumbnail view with async image loading and visionOS hover effects.
 */

import SwiftUI

struct GalleryThumbnailView: View {
    let image: GalleryImage
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 200)
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .frame(width: 200, height: 200)
            } else {
                // Error state
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    if loadFailed {
                        Text("Failed to load")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 200, height: 200)
            }
        }
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(12)
        .hoverEffect(.lift)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            loadedImage = try await ImageLoader.shared.loadImage(from: image.thumbnailURL)
            if loadedImage == nil {
                loadFailed = true
            }
        } catch {
            print("Failed to load thumbnail: \(error)")
            loadFailed = true
        }
        isLoading = false
    }
}
