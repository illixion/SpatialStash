/*
 Spatial Stash - Video Thumbnail View

 Individual video thumbnail with duration overlay.
 */

import os
import SwiftUI

struct VideoThumbnailView: View {
    let video: GalleryVideo
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Background
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
            
            // Thumbnail image
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "video")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
            }

            // Play button overlay
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
                .shadow(radius: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom badges (3D indicator and duration)
            HStack(spacing: 6) {
                // 3D badge for stereoscopic videos
                if video.isStereoscopic {
                    HStack(spacing: 2) {
                        Image(systemName: "view.3d")
                            .font(.caption2)
                        if let format = video.stereoscopicFormat {
                            Text(format.shortLabel)
                                .font(.caption2)
                                .fontWeight(.semibold)
                        } else {
                            Text("3D")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }

                Spacer()

                // Duration badge
                if let duration = video.formattedDuration {
                    Text(duration)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
            .padding(8)
        }
        .aspectRatio(16/9, contentMode: .fit)
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .hoverEffect(ScaleHoverEffect())
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Use efficient thumbnail loading
        if let image = await ImageLoader.shared.loadThumbnail(from: video.thumbnailURL) {
            // Crop to 16:9
            loadedImage = cropTo16x9(image)
        } else {
            AppLogger.views.warning("Failed to load video thumbnail: \(video.thumbnailURL.lastPathComponent, privacy: .private)")
            loadFailed = true
        }
        isLoading = false
    }
    
    private func cropTo16x9(_ image: UIImage) -> UIImage {
        let targetAspect: CGFloat = 16.0 / 9.0
        let imageAspect = image.size.width / image.size.height
        
        var cropRect: CGRect
        
        if imageAspect > targetAspect {
            // Image is wider than 16:9, crop width
            let targetWidth = image.size.height * targetAspect
            let xOffset = (image.size.width - targetWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: targetWidth, height: image.size.height)
        } else {
            // Image is taller than 16:9, crop height
            let targetHeight = image.size.width / targetAspect
            let yOffset = (image.size.height - targetHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: image.size.width, height: targetHeight)
        }
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
