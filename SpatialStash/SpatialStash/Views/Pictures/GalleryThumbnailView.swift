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

            if let dioramaPair, appModel.effectiveThumbnailDiorama {
                // Two-layer diorama: blurred-subject backdrop, masked foreground
                // popped forward in z for an Apple TV-style parallax pop.
                Image(uiImage: dioramaPair.backdrop)
                    .resizable()
                    .scaledToFill()
                Image(uiImage: dioramaPair.foreground)
                    .resizable()
                    .scaledToFill()
                    .offset(z: 24)
            } else if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                if appModel.effectiveThumbnailSpatial3D {
                    // RealityKit 2D→3D conversion runs on a 128px
                    // downsample. The base 2D image stays visible until
                    // generate() finishes, then the spatial layer
                    // crossfades in on top.
                    GalleryThumbnailSpatial3DView(baseImage: loadedImage)
                }
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
            // Load base thumbnail and any cached diorama in parallel so a
            // disk-warm pair lands in the same render commit as the base —
            // no foreground pop-in on scroll.
            async let baseTask: Void = loadThumbnail()
            async let cachedDioramaTask: ThumbnailDioramaCache.Pair? = preloadCachedDiorama()
            _ = await baseTask
            if let pair = await cachedDioramaTask {
                dioramaPair = pair
            } else {
                await generateDioramaIfPossible()
            }
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
            dioramaPair = nil
        }
    }

    /// Memory + disk lookup only — never invokes Vision. Returns `nil` if
    /// no cached pair exists, in which case the caller falls through to
    /// `generateDioramaIfPossible()` for cold generation.
    private func preloadCachedDiorama() async -> ThumbnailDioramaCache.Pair? {
        guard appModel.effectiveThumbnailDiorama else { return nil }
        return await ThumbnailDioramaCache.shared.cachedOrDisk(for: image.thumbnailURL)
    }

    /// Cold-path generation: kicks off Vision-driven foreground/backdrop
    /// generation. A short debounce avoids queuing work for thumbnails
    /// that scroll past quickly.
    private func generateDioramaIfPossible() async {
        guard let loadedImage else { return }
        guard appModel.effectiveThumbnailDiorama else { return }
        let key = image.thumbnailURL
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
