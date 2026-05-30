/*
 Spatial Stash - Quick Look 3D Preview

 Tap-and-hold "Quick Look" preview presented over the gallery grid.
 Mirrors iOS 3D Touch's pop-out behavior on photos: the source cell's
 frame is matched via `matchedGeometryEffect`, and the preview expands
 from that frame to fill the container while RealityKit converts the
 full-size image to a Spatial3DImage at the user's configured 3D
 resolution. Tap anywhere or swipe down to dismiss; the animation
 reverses back into the source cell.

 Only one preview is alive at a time — important because RealityKit
 enforces a hard cap on concurrent ImagePresentationComponent
 instances on visionOS.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct QuickLook3DView: View {
    @Environment(AppModel.self) private var appModel
    let image: GalleryImage
    let namespace: Namespace.ID
    let onDismiss: () -> Void

    @State private var entity = Entity()
    @State private var aspectRatio: CGFloat = 1
    @State private var spatialReady = false
    @State private var loadFailed = false
    @State private var loadedImage: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            GeometryReader { geo in
                let maxW = geo.size.width * 0.92
                let maxH = geo.size.height * 0.92
                let fitted = fittedSize(in: CGSize(width: maxW, height: maxH))

                ZStack {
                    if let loadedImage {
                        Image(uiImage: loadedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: fitted.width, height: fitted.height)
                            .clipped()
                    } else {
                        Color.secondary.opacity(0.2)
                            .frame(width: fitted.width, height: fitted.height)
                    }

                    if spatialReady {
                        GeometryReader3D { geometry3D in
                            RealityView { content in
                                content.add(entity)
                                scaleEntityToFit(content: content, geometry: geometry3D)
                            } update: { content in
                                scaleEntityToFit(content: content, geometry: geometry3D)
                            }
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .transition(.opacity)
                    }

                    if !spatialReady && !loadFailed {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .cornerRadius(20)
                .matchedGeometryEffect(id: image.id, in: namespace, isSource: false)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            if abs(value.translation.height) > 60 || abs(value.translation.width) > 60 {
                                onDismiss()
                            }
                        }
                )
            }
        }
        .task(id: image.id) {
            await load()
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = max(aspectRatio, 0.0001)
        let containerRatio = container.width / container.height
        if ratio >= containerRatio {
            return CGSize(width: container.width, height: container.width / ratio)
        } else {
            return CGSize(width: container.height * ratio, height: container.height)
        }
    }

    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let presentation = ipc.presentationScreenSize
        guard presentation.x > 0, presentation.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(
            bounds.extents.x / presentation.x,
            bounds.extents.y / presentation.y
        )
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    @MainActor
    private func load() async {
        spatialReady = false
        loadFailed = false
        loadedImage = nil

        let sourceURL = image.fullSizeURL
        let maxDim = appModel.spatial3DMaxResolution

        // Resolve to a local file: cache hit on disk, file URL passthrough,
        // or download into the disk cache.
        let localURL: URL
        if sourceURL.isFileURL {
            localURL = sourceURL
        } else if let cached = await DiskImageCache.shared.cachedFileURL(for: sourceURL) {
            localURL = cached
        } else {
            do {
                guard let data = try await ImageLoader.shared.loadRawData(from: sourceURL) else {
                    loadFailed = true; return
                }
                await DiskImageCache.shared.saveData(data, for: sourceURL)
                guard let cached = await DiskImageCache.shared.cachedFileURL(for: sourceURL) else {
                    loadFailed = true; return
                }
                localURL = cached
            } catch {
                AppLogger.views.warning("QuickLook3DView: download failed: \(error.localizedDescription, privacy: .public)")
                loadFailed = true
                return
            }
        }

        if Task.isCancelled { return }

        // Show the 2D image immediately as a backdrop while RealityKit
        // generates the depth map.
        if let preview = UIImage(contentsOfFile: localURL.path) {
            loadedImage = preview
            if preview.size.height > 0 {
                aspectRatio = preview.size.width / preview.size.height
            }
        }

        // Build the Spatial3DImage from a JPEG capped at the user's
        // configured 3D resolution. 0 = no cap (native resolution).
        let spatial: ImagePresentationComponent.Spatial3DImage
        do {
            if maxDim > 0,
               let downsampled = PhotoWindowModel.createDownsampledImageData(from: localURL, maxDimension: CGFloat(maxDim)),
               let source = CGImageSourceCreateWithData(downsampled as CFData, nil) {
                spatial = try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
            } else {
                spatial = try await ImagePresentationComponent.Spatial3DImage(contentsOf: localURL)
            }
        } catch {
            AppLogger.views.warning("QuickLook3DView: Spatial3DImage init failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
            return
        }

        if Task.isCancelled { return }

        var ipc = ImagePresentationComponent(spatial3DImage: spatial)
        ipc.desiredViewingMode = .spatial3D
        entity.components.set(ipc)
        if let ar = ipc.aspectRatio(for: .spatial3D) {
            aspectRatio = CGFloat(ar)
        }

        // Strong-ref hold across generate(): RealityKit's progress
        // callbacks crash if the entity is freed mid-flight. Mirrors
        // SlideshowSpatial3DSlotView's pattern.
        let heldEntity = entity
        let heldSpatial = spatial
        Task { @MainActor in
            do {
                try await heldSpatial.generate()
                withAnimation(.easeInOut(duration: 0.25)) {
                    spatialReady = true
                }
            } catch {
                AppLogger.views.warning("QuickLook3DView: generate failed: \(error.localizedDescription, privacy: .public)")
                loadFailed = true
            }
            _ = heldEntity
        }
    }
}
