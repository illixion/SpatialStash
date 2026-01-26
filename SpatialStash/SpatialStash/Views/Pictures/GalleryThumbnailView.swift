/*
 Spatial Stash - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import SwiftUI

struct GalleryThumbnailView: View {
    let image: GalleryImage
    var onTap: (() -> Void)? = nil
    @State private var loadedImage: UIImage?
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isAnimatedGIF = false

    var body: some View {
        ZStack {
            // Background
            Color.secondary.opacity(0.2)
            
            if let imageData, isAnimatedGIF {
                // Display animated GIF
                AnimatedImageView(data: imageData, contentMode: .scaleAspectFill)
                    .frame(width: 200, height: 200)
            } else if let loadedImage {
                // Display static image
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
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
            }
        }
        .frame(width: 200, height: 200)
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .hoverEffect(ScaleHoverEffect())
        .onTapGesture {
            onTap?()
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            if let result = try await ImageLoader.shared.loadImageWithData(from: image.thumbnailURL) {
                // Crop to square
                loadedImage = cropToSquare(result.image)
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
    
    private func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2
        
        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
