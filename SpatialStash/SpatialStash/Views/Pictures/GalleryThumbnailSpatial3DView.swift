/*
 Spatial Stash - Gallery Thumbnail Spatial 3D View

 Per-cell RealityKit overlay that runs RealityKit's 2D→3D conversion
 on a 128px downsample of the cell's thumbnail and crossfades the
 depth-mapped scene over the regular 2D image once generation finishes.

 Modeled after `SlideshowSpatial3DSlotView`: a single entity owns an
 `ImagePresentationComponent`, generation runs in a strong-ref-held
 detached `Task { @MainActor }` so RealityKit's progress callbacks
 land on valid memory if the cell goes away mid-generate. The
 "discard on scroll-away" behavior comes from the SwiftUI `.task`
 modifier — a 400ms `Task.sleep` runs first, and cells that scroll
 past quickly never start generation at all (matches the diorama
 cold-path pattern in `GalleryThumbnailView`).
 */

import ImageIO
import os
import RealityKit
import SwiftUI
import UIKit

/// Target source dimension for the 3D conversion. Small enough that
/// `Spatial3DImage.generate()` stays cheap per-cell across a full grid.
private let thumbnailSpatial3DSourceDimension: CGFloat = 128

struct GalleryThumbnailSpatial3DView: View {
    /// The already-loaded 2D thumbnail. Downsampled to ~128px before
    /// being handed to the Spatial3DImage initializer.
    let baseImage: UIImage

    @State private var entity = Entity()
    @State private var isReady = false
    @State private var loadedKey: ObjectIdentifier?

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                content.add(entity)
                scaleEntityToFit(content: content, geometry: geometry)
            } update: { content in
                scaleEntityToFit(content: content, geometry: geometry)
            }
        }
        .opacity(isReady ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isReady)
        .task(id: ObjectIdentifier(baseImage)) {
            await reload()
        }
    }

    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let size = ipc.presentationScreenSize
        guard size.x > 0, size.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(bounds.extents.x / size.x, bounds.extents.y / size.y)
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    @MainActor
    private func reload() async {
        let key = ObjectIdentifier(baseImage)
        if loadedKey == key, isReady { return }
        isReady = false

        // 400ms debounce so cells that scroll past quickly never start
        // the work — Task.sleep is the only cancellable phase, since
        // RealityKit's generate() ignores cooperative cancellation.
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return
        }

        let source = baseImage
        guard let data = await Task.detached(priority: .utility, operation: {
            Self.downsampledJPEGData(from: source, maxDimension: thumbnailSpatial3DSourceDimension)
        }).value else {
            AppLogger.views.warning("GalleryThumbnailSpatial3DView: downsample failed")
            return
        }

        guard !Task.isCancelled else { return }

        do {
            let spatial = try await Self.makeSpatial3DImage(from: data)
            var ipc = ImagePresentationComponent(spatial3DImage: spatial)
            ipc.desiredViewingMode = .spatial3D
            entity.components.set(ipc)
            loadedKey = key

            // Strong-ref hold across detached generate(): RealityKit's
            // progress callbacks crash if the entity is freed mid-flight.
            // Mirrors SlideshowSpatial3DSlotView's pattern — let the work
            // run to completion even if this view goes away. The result
            // is silently discarded since the SwiftUI state is gone.
            let heldEntity = entity
            let heldSpatial = spatial
            Task { @MainActor in
                do {
                    try await heldSpatial.generate()
                    isReady = true
                } catch {
                    AppLogger.views.warning("GalleryThumbnailSpatial3DView: generate failed: \(error.localizedDescription, privacy: .public)")
                }
                _ = heldEntity
            }
        } catch {
            AppLogger.views.warning("GalleryThumbnailSpatial3DView: Spatial3DImage init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func makeSpatial3DImage(from data: Data) async throws -> ImagePresentationComponent.Spatial3DImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
    }

    private nonisolated static func downsampledJPEGData(from image: UIImage, maxDimension: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else {
            return image.jpegData(compressionQuality: 0.9)
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        if max(width, height) <= maxDimension {
            return image.jpegData(compressionQuality: 0.9)
        }
        guard let data = image.jpegData(compressionQuality: 0.95),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }
}
