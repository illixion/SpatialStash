/*
 Spatial Stash - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import os
import SwiftUI

struct GalleryThumbnailView: View {
    let image: GalleryImage
    var onTap: (() -> Void)? = nil
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            // Background
            Color.secondary.opacity(0.2)
            
            if let loadedImage {
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
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
        }
    }

    private func loadThumbnail() async {
        if image.thumbnailURL.isFileURL {
            // Local files: use efficient downsampling path
            if let result = await ImageLoader.shared.loadThumbnailWithData(from: image.thumbnailURL) {
                loadedImage = Self.cropToSquare(result.image)
            } else {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        } else {
            // Remote URLs: use cached thumbnail path (stores cropped result in ThumbnailCache)
            if let result = await ImageLoader.shared.loadRemoteThumbnailCached(from: image.thumbnailURL, crop: Self.cropToSquare) {
                loadedImage = result
            } else {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        }
        isLoading = false
    }
    
    private nonisolated static func cropToSquare(_ image: UIImage) -> UIImage {
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
