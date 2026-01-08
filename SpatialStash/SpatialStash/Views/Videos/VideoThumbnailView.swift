/*
 Spatial Stash - Video Thumbnail View

 Individual video thumbnail with duration overlay.
 */

import SwiftUI

struct VideoThumbnailView: View {
    let video: GalleryVideo
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Thumbnail image
            ZStack {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 150)
                        .clipped()
                } else if isLoading {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 150)
                        .overlay {
                            ProgressView()
                        }
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 150)
                        .overlay {
                            Image(systemName: "video")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        }
                }
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
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(12)
        .hoverEffect(.lift)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            loadedImage = try await ImageLoader.shared.loadImage(from: video.thumbnailURL)
            if loadedImage == nil {
                loadFailed = true
            }
        } catch {
            print("Failed to load video thumbnail: \(error)")
            loadFailed = true
        }
        isLoading = false
    }
}
