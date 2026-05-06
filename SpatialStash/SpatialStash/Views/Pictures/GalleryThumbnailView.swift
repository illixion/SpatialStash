/*
 Spatial Stash - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import os
import SwiftUI

struct GalleryThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    let image: GalleryImage
    var onTap: (() -> Void)? = nil
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var dioramaPair: ThumbnailDioramaCache.Pair?

    var body: some View {
        ZStack {
            // Background
            Color.secondary.opacity(0.2)

            if let dioramaPair, !appModel.effectiveReduceMotion {
                // Both layers always rendered, both at z=0 — looks flat at
                // rest. On gaze the foreground scales beyond the container's
                // hover scale and tilts slightly, reading as forward motion
                // without needing dynamic z-offset (which the hover-effect
                // transform vocabulary doesn't expose).
                Image(uiImage: dioramaPair.backdrop)
                    .resizable()
                    .scaledToFill()
                Image(uiImage: dioramaPair.foreground)
                    .resizable()
                    .scaledToFill()
                    .hoverEffect(DioramaForegroundHoverEffect())
            } else if let loadedImage {
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
        .modifier(ThumbnailHoverModifier(reduceMotion: appModel.effectiveReduceMotion))
        .onTapGesture {
            onTap?()
        }
        .task {
            await loadThumbnail()
            await generateDioramaIfPossible()
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
            dioramaPair = nil
        }
    }

    /// After the thumbnail bitmap is on screen, kick off Vision-driven
    /// foreground/backdrop generation. A short debounce avoids queuing
    /// work for thumbnails that scroll past quickly. The cache hands back
    /// any in-flight or completed result without re-running Vision.
    private func generateDioramaIfPossible() async {
        guard let loadedImage else { return }
        guard !appModel.effectiveReduceMotion else { return }
        let key = image.thumbnailURL
        if let cached = ThumbnailDioramaCache.shared.cached(for: key) {
            dioramaPair = cached
            return
        }
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return // cancelled (scrolled away)
        }
        let pair = await ThumbnailDioramaCache.shared.dioramaPair(for: key) { loadedImage }
        guard !Task.isCancelled else { return }
        dioramaPair = pair
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
    
    /// Wraps the thumbnail's hover effect choice. Reduce-motion swaps the
    /// scale-up animation for the system default highlight so gaze still
    /// gives feedback without movement.
    private struct ThumbnailHoverModifier: ViewModifier {
        let reduceMotion: Bool

        func body(content: Content) -> some View {
            if reduceMotion {
                content.hoverEffect(.highlight)
            } else {
                content.hoverEffect(ScaleHoverEffect())
            }
        }
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
