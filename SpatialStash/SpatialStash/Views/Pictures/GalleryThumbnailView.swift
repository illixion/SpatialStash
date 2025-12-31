/*
 Spatial Stash - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import SwiftUI

struct GalleryThumbnailView: View {
    let image: GalleryImage
    @State private var loadedImage: UIImage?
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isAnimatedGIF = false

    var body: some View {
        ZStack {
            if let imageData, isAnimatedGIF {
                // Display animated GIF
                AnimatedImageView(data: imageData, contentMode: .scaleAspectFill)
                    .frame(width: 200, height: 200)
            } else if let loadedImage {
                // Display static image
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
        .clipped()
        .hoverEffect(.lift)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            if let result = try await ImageLoader.shared.loadImageWithData(from: image.thumbnailURL) {
                loadedImage = result.image
                imageData = result.data
                isAnimatedGIF = result.data.isAnimatedGIF
            } else {
                loadFailed = true
            }
        } catch {
            print("Failed to load thumbnail: \(error)")
            loadFailed = true
        }
        isLoading = false
    }
}
